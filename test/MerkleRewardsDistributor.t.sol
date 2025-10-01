// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {MerkleRewardsDistributor} from "../contracts/MerkleRewardsDistributor.sol";
import {ERC20MinterPauser} from "../contracts/ERC20MinterPauser.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MerkleRewardsDistributorTest is Test {
  MerkleRewardsDistributor internal distributor;
  ERC20MinterPauser internal token;

  address internal deployer = address(this);
  address internal alice;
  address internal bob;
  address internal carol;

  function setUp() public {
    alice = makeAddr("ALICE");
    bob = makeAddr("BOB");
    carol = makeAddr("CAROL");

    address implementation = address(new MerkleRewardsDistributor());
    bytes memory initData = abi.encodeCall(MerkleRewardsDistributor.initialize, (deployer));
    ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
    distributor = MerkleRewardsDistributor(address(proxy));

    token = new ERC20MinterPauser("Test Token", "TEST");
    token.mint(address(distributor), 1_000_000 ether);
  }

  // local Merkle builder (keccak abi.encode)
  function _leaf(uint256 index, address account, address tokenAddr, uint256 amount, string memory contestType, string memory periodId)
    internal pure returns (bytes32)
  {
    return keccak256(abi.encode(index, account, tokenAddr, amount, contestType, periodId));
  }

  function _buildRoot(bytes32[] memory leaves) internal pure returns (bytes32 root) {
    if (leaves.length == 0) return bytes32(0);
    while (leaves.length > 1) {
      uint256 n = (leaves.length + 1) / 2;
      bytes32[] memory next = new bytes32[](n);
      for (uint256 i = 0; i < leaves.length; i += 2) {
        bytes32 left = leaves[i];
        bytes32 right = (i + 1 < leaves.length) ? leaves[i + 1] : left;
        next[i/2] = _parent(left, right);
      }
      leaves = next;
    }
    return leaves[0];
  }

  function _parent(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    (bytes32 left, bytes32 right) = a <= b ? (a,b) : (b,a);
    return keccak256(abi.encodePacked(left, right));
  }

  function _proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory p) {
    // Build layers copying logic from _buildRoot to also record siblings
    bytes32[] memory current = leaves;
    bytes32[] memory proofTmp = new bytes32[](64);
    uint256 proofLen = 0;
    uint256 idx = index;
    while (current.length > 1) {
      uint256 n = (current.length + 1) / 2;
      bytes32[] memory next = new bytes32[](n);
      for (uint256 i = 0; i < current.length; i += 2) {
        bytes32 left = current[i];
        bytes32 right = (i + 1 < current.length) ? current[i + 1] : left;
        next[i/2] = _parent(left, right);
        if (i == (idx ^ 1) - 1 || i == (idx & ~uint256(1))) {
          // sibling for this level
          bytes32 sib = (idx % 2 == 0) ? right : left;
          if (i + 1 >= current.length && idx % 2 == 1) {
            // when paired with itself, skip duplicate sibling
          } else {
            proofTmp[proofLen++] = sib;
          }
        }
      }
      current = next;
      idx >>= 1;
    }
    p = new bytes32[](proofLen);
    for (uint256 i = 0; i < proofLen; i++) p[i] = proofTmp[i];
  }

  function test_PublishRootAndSingleClaim() public {
    string memory ct = "daily";
    string memory pid = "2025-09-30";

    bytes32[] memory leaves = new bytes32[](2);
    leaves[0] = _leaf(0, alice, address(token), 100 ether, ct, pid);
    leaves[1] = _leaf(1, bob, address(token), 200 ether, ct, pid);
    bytes32 root = _buildRoot(leaves);

    distributor.publishRoot(ct, pid, IERC20(address(token)), root);
    assertEq(distributor.getRoot(ct, pid, IERC20(address(token))), root);

    bytes32[] memory proofAlice = _proof(leaves, 0);
    assertFalse(distributor.isClaimed(ct, pid, IERC20(address(token)), 0));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 100 ether, proofAlice);
    assertTrue(distributor.isClaimed(ct, pid, IERC20(address(token)), 0));
    assertEq(token.balanceOf(alice), 100 ether);
  }

  function test_RevertOnInvalidProof() public {
    string memory ct = "weekly";
    string memory pid = "2025-W40";

    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = _leaf(0, alice, address(token), 50 ether, ct, pid);
    bytes32 root = _buildRoot(leaves);
    distributor.publishRoot(ct, pid, IERC20(address(token)), root);

    bytes32[] memory wrongProof = new bytes32[](0);
    vm.expectRevert(bytes("MerkleRewards: invalid proof"));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 51 ether, wrongProof);
  }

  function test_RevertOnDoubleClaim() public {
    string memory ct = "monthly";
    string memory pid = "2025-09";

    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = _leaf(0, alice, address(token), 10 ether, ct, pid);
    bytes32 root = _buildRoot(leaves);
    distributor.publishRoot(ct, pid, IERC20(address(token)), root);

    bytes32[] memory proof = _proof(leaves, 0);
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 10 ether, proof);

    vm.expectRevert(bytes("MerkleRewards: already claimed"));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 10 ether, proof);
  }

  function test_ClaimMany() public {
    string memory ct1 = "daily";
    string memory pid1 = "2025-09-30";
    string memory ct2 = "weekly";
    string memory pid2 = "2025-W40";

    bytes32[] memory leaves1 = new bytes32[](1);
    leaves1[0] = _leaf(0, alice, address(token), 100 ether, ct1, pid1);
    bytes32 root1 = _buildRoot(leaves1);
    distributor.publishRoot(ct1, pid1, IERC20(address(token)), root1);

    bytes32[] memory leaves2 = new bytes32[](2);
    leaves2[0] = _leaf(0, alice, address(token), 5 ether, ct2, pid2);
    leaves2[1] = _leaf(1, bob, address(token), 7 ether, ct2, pid2);
    bytes32 root2 = _buildRoot(leaves2);
    distributor.publishRoot(ct2, pid2, IERC20(address(token)), root2);

    string[] memory cts = new string[](2);
    cts[0] = ct1; cts[1] = ct2;
    string[] memory pids = new string[](2);
    pids[0] = pid1; pids[1] = pid2;
    IERC20[] memory tokens = new IERC20[](2);
    tokens[0] = IERC20(address(token)); tokens[1] = IERC20(address(token));
    uint256[] memory idxs = new uint256[](2);
    idxs[0] = 0; idxs[1] = 0;
    address[] memory accts = new address[](2);
    accts[0] = alice; accts[1] = alice;
    uint256[] memory amts = new uint256[](2);
    amts[0] = 100 ether; amts[1] = 5 ether;
    bytes32[][] memory proofs = new bytes32[][](2);
    proofs[0] = _proof(leaves1, 0);
    proofs[1] = _proof(leaves2, 0);

    distributor.claimMany(cts, pids, tokens, idxs, accts, amts, proofs);
    assertTrue(distributor.isClaimed(ct1, pid1, IERC20(address(token)), 0));
    assertTrue(distributor.isClaimed(ct2, pid2, IERC20(address(token)), 0));
    assertEq(token.balanceOf(alice), 105 ether);
  }

  function test_AdminWithdraw() public {
    uint256 balBefore = token.balanceOf(address(distributor));
    distributor.withdraw(IERC20(address(token)), 1 ether);
    assertEq(token.balanceOf(address(distributor)), balBefore - 1 ether);
    assertEq(token.balanceOf(deployer), 1 ether);
  }

  function test_OnlyOwnerGuards() public {
    string memory ct = "daily";
    string memory pid = "2025-10-01";
    bytes32 dummyRoot = bytes32(uint256(1));

    vm.prank(alice);
    vm.expectRevert();
    distributor.publishRoot(ct, pid, IERC20(address(token)), dummyRoot);

    vm.prank(alice);
    vm.expectRevert();
    distributor.withdraw(IERC20(address(token)), 1);
  }

  function test_AdminRoleCanPublishRoot() public {
    // grant admin to alice and publish
    distributor.addAdmin(alice);
    assertTrue(distributor.isAdmin(alice));

    string memory ct = "daily";
    string memory pid = "2025-10-05";
    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = _leaf(0, alice, address(token), 1 ether, ct, pid);
    bytes32 root = _buildRoot(leaves);

    vm.prank(alice);
    distributor.publishRoot(ct, pid, IERC20(address(token)), root);
    assertEq(distributor.getRoot(ct, pid, IERC20(address(token))), root);

    // remove admin and ensure access revoked
    distributor.removeAdmin(alice);
    assertFalse(distributor.isAdmin(alice));
    vm.prank(alice);
    vm.expectRevert(bytes("MerkleRewards: must have admin role"));
    distributor.publishRoot(ct, pid, IERC20(address(token)), root);
  }

  function test_RootNotSet_RevertOnClaim() public {
    string memory ct = "weekly";
    string memory pid = "2025-W41";
    bytes32[] memory proof = new bytes32[](0);
    vm.expectRevert(bytes("MerkleRewards: root not set"));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 1, proof);
  }

  function test_RootUpdateInvalidatesOldProof() public {
    string memory ct = "monthly";
    string memory pid = "2025-10";

    // first root
    bytes32[] memory leaves1 = new bytes32[](1);
    leaves1[0] = _leaf(0, alice, address(token), 10 ether, ct, pid);
    bytes32 root1 = _buildRoot(leaves1);
    distributor.publishRoot(ct, pid, IERC20(address(token)), root1);
    bytes32[] memory proof1 = _proof(leaves1, 0);

    // update root with different allocation
    bytes32[] memory leaves2 = new bytes32[](1);
    leaves2[0] = _leaf(0, alice, address(token), 20 ether, ct, pid);
    bytes32 root2 = _buildRoot(leaves2);
    distributor.publishRoot(ct, pid, IERC20(address(token)), root2);

    // old proof must fail now
    vm.expectRevert(bytes("MerkleRewards: invalid proof"));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 10 ether, proof1);

    // new proof succeeds
    bytes32[] memory proof2 = _proof(leaves2, 0);
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 20 ether, proof2);
    assertEq(token.balanceOf(alice), 20 ether);
  }

  function test_ClaimWithWrongTokenOrPeriod() public {
    string memory ct = "daily";
    string memory pid = "2025-10-02";
    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = _leaf(0, alice, address(token), 5 ether, ct, pid);
    distributor.publishRoot(ct, pid, IERC20(address(token)), _buildRoot(leaves));
    bytes32[] memory proof = _proof(leaves, 0);

    // wrong token -> root not set for that key
    ERC20MinterPauser other = new ERC20MinterPauser("Other", "OTH");
    vm.expectRevert(bytes("MerkleRewards: root not set"));
    distributor.claim(ct, pid, IERC20(address(other)), 0, alice, 5 ether, proof);

    // wrong amount -> invalid proof
    vm.expectRevert(bytes("MerkleRewards: invalid proof"));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 6 ether, proof);
  }

  function test_IsClaimedReflectsState() public {
    string memory ct = "daily";
    string memory pid = "2025-10-03";
    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = _leaf(0, alice, address(token), 1 ether, ct, pid);
    distributor.publishRoot(ct, pid, IERC20(address(token)), _buildRoot(leaves));
    assertFalse(distributor.isClaimed(ct, pid, IERC20(address(token)), 0));
    distributor.claim(ct, pid, IERC20(address(token)), 0, alice, 1 ether, _proof(leaves, 0));
    assertTrue(distributor.isClaimed(ct, pid, IERC20(address(token)), 0));
  }

  function test_ClaimMany_LengthMismatchReverts() public {
    string[] memory ct = new string[](1);
    ct[0] = "daily";
    string[] memory pid = new string[](1);
    pid[0] = "2025-10-04";
    IERC20[] memory toks = new IERC20[](1);
    toks[0] = IERC20(address(token));
    uint256[] memory idx = new uint256[](1);
    idx[0] = 0;
    address[] memory accts = new address[](1);
    accts[0] = alice;
    // amounts empty to force mismatch
    uint256[] memory amts = new uint256[](0);
    bytes32[][] memory proofs = new bytes32[][](1);
    proofs[0] = new bytes32[](0);

    vm.expectRevert(bytes("MerkleRewards: arrays length mismatch"));
    distributor.claimMany(ct, pid, toks, idx, accts, amts, proofs);
  }

  function test_ClaimMany_DuplicateIndexReverts() public {
    string memory ct = "weekly";
    string memory pid = "2025-W42";
    bytes32[] memory leaves = new bytes32[](1);
    leaves[0] = _leaf(0, alice, address(token), 3 ether, ct, pid);
    distributor.publishRoot(ct, pid, IERC20(address(token)), _buildRoot(leaves));

    string[] memory cts = new string[](2);
    cts[0] = ct; cts[1] = ct;
    string[] memory pids = new string[](2);
    pids[0] = pid; pids[1] = pid;
    IERC20[] memory toks = new IERC20[](2);
    toks[0] = IERC20(address(token)); toks[1] = IERC20(address(token));
    uint256[] memory idxs = new uint256[](2);
    idxs[0] = 0; idxs[1] = 0; // duplicate same index
    address[] memory accts = new address[](2);
    accts[0] = alice; accts[1] = alice;
    uint256[] memory amts = new uint256[](2);
    amts[0] = 3 ether; amts[1] = 3 ether;
    bytes32[][] memory proofs = new bytes32[][](2);
    proofs[0] = _proof(leaves, 0);
    proofs[1] = _proof(leaves, 0);

    vm.expectRevert(bytes("MerkleRewards: already claimed"));
    distributor.claimMany(cts, pids, toks, idxs, accts, amts, proofs);
  }
}
