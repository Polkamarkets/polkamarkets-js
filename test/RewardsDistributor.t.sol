// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RewardsDistributor} from "../contracts/RewardsDistributor.sol";
import {ERC20MinterPauser} from "../contracts/ERC20MinterPauser.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RewardsDistributorTest is Test {
  using ECDSA for bytes32;
  using MessageHashUtils for bytes32;

  RewardsDistributor internal distributor;
  ERC20MinterPauser internal token;

  address internal deployer = address(this);
  address internal user1;
  uint256 internal user1Pk;
  address internal user2;
  uint256 internal user2Pk;
  address internal user3;
  uint256 internal user3Pk;

  function setUp() public {
    // create test keys
    (user1, user1Pk) = makeAddrAndKey("USER1");
    (user2, user2Pk) = makeAddrAndKey("USER2");
    (user3, user3Pk) = makeAddrAndKey("USER3");

    address implementation = address(new RewardsDistributor());
    bytes memory initData = abi.encodeCall(RewardsDistributor.initialize, (deployer));
    ERC1967Proxy proxy = new ERC1967Proxy(implementation, initData);
    distributor = RewardsDistributor(address(proxy));
    token = new ERC20MinterPauser("Test Token", "TEST");

    // mint tokens to distributor contract
    token.mint(address(distributor), 100000);
  }

  // helpers
  function _signClaim(address user, address receiver, uint256 amount, address tokenAddress, uint256 pk)
    internal view
    returns (uint256 nonce, bytes memory signature)
  {
    // Get next nonce from contract perspective by calling nonces on inherited Nonces
    // RewardsDistributor exposes _useCheckedNonce internally only, so we rely on the storage behavior:
    // The JS test obtains nonce off-chain; here we'll simulate by reading public view nonces if exposed.
    // Nonces.nonces is public in our local Nonces contract.
    nonce = distributor.nonces(user);

    bytes32 msgHash = keccak256(abi.encodePacked(user, receiver, amount, tokenAddress, nonce)).toEthSignedMessageHash();
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, msgHash);
    signature = abi.encodePacked(r, s, v);
  }

  function test_ContractDeploymentAndAdmin() public view {
    // deployer should be admin
    bool isAdmin = distributor.isAdmin(deployer);
    assertTrue(isAdmin);
  }

  function test_AddAmountToClaimAndClaimByOtherUser() public {
    // Initially 0
    uint256 amountToClaim0 = distributor.amountToClaim(user1, IERC20(address(token)));
    assertEq(amountToClaim0, 0);

    // Add amount for user1 by admin (deployer)
    bytes32 opId = keccak256(abi.encodePacked("op", uint256(1)));
    distributor.increaseUserClaimAmount(user1, 1000, IERC20(address(token)), opId);
    uint256 amountToClaim = distributor.amountToClaim(user1, IERC20(address(token)));
    assertEq(amountToClaim, 1000);

    // balances
    uint256 balDistributorBefore = token.balanceOf(address(distributor));
    uint256 balUser1Before = token.balanceOf(user1);
    uint256 balUser2Before = token.balanceOf(user2);
    assertGt(balDistributorBefore, 0);
    assertEq(balUser1Before, 0);
    assertEq(balUser2Before, 0);

    // sign by user1, claim to user2
    (uint256 nonce, bytes memory sig) = _signClaim(user1, user2, amountToClaim, address(token), user1Pk);

    // user2 calls claim
    vm.prank(user2);
    distributor.claim(user1, user2, amountToClaim, IERC20(address(token)), nonce, sig);

    // check amounts and balances
    uint256 amountLeft = distributor.amountToClaim(user1, IERC20(address(token)));
    assertEq(amountLeft, 0);

    uint256 balDistributorAfter = token.balanceOf(address(distributor));
    uint256 balUser1After = token.balanceOf(user1);
    uint256 balUser2After = token.balanceOf(user2);
    assertEq(balDistributorAfter, balDistributorBefore - amountToClaim);
    assertEq(balUser1After, 0);
    assertEq(balUser2After, balUser2Before + amountToClaim);
  }

  function test_RevertWhen_NoAmountToClaim() public {
    // user1 has 0
    assertEq(distributor.amountToClaim(user1, IERC20(address(token))), 0);

    // sign some amount anyway
    (uint256 nonce, bytes memory sig) = _signClaim(user1, user2, 1000, address(token), user1Pk);

    // user2 tries to claim -> revert
    vm.prank(user2);
    vm.expectRevert(bytes("RewardsDistributor: not enough tokens to claim"));
    distributor.claim(user1, user2, 1000, IERC20(address(token)), nonce, sig);
  }

  function test_RevertWhen_ReceiverDiffersFromSigned() public {
    // add amount for user1
    bytes32 opId1 = keccak256(abi.encodePacked("op", uint256(2)));
    distributor.increaseUserClaimAmount(user1, 1000, IERC20(address(token)), opId1);

    uint256 amountToClaim = distributor.amountToClaim(user1, IERC20(address(token)));
    assertGt(amountToClaim, 0);

    // sign to user2
    (uint256 nonce, bytes memory sig) = _signClaim(user1, user2, amountToClaim, address(token), user1Pk);

    // try claiming to user3
    vm.prank(user2);
    vm.expectRevert(bytes("RewardsDistributor: invalid signature"));
    distributor.claim(user1, user3, amountToClaim, IERC20(address(token)), nonce, sig);

    // amount unchanged
    uint256 left = distributor.amountToClaim(user1, IERC20(address(token)));
    assertEq(left, amountToClaim);
  }

  function test_RevertWhen_AmountDiffersFromSigned() public {
    // add amount for user1
    bytes32 opId2 = keccak256(abi.encodePacked("op", uint256(3)));
    distributor.increaseUserClaimAmount(user1, 1000, IERC20(address(token)), opId2);

    uint256 amountToClaim = distributor.amountToClaim(user1, IERC20(address(token)));
    assertGt(amountToClaim, 0);

    uint256 half = amountToClaim / 2;
    (uint256 nonce, bytes memory sig) = _signClaim(user1, user2, half, address(token), user1Pk);

    // claim full amount (different than signed) -> revert invalid signature
    vm.prank(user2);
    vm.expectRevert(bytes("RewardsDistributor: invalid signature"));
    distributor.claim(user1, user2, amountToClaim, IERC20(address(token)), nonce, sig);
  }

  function test_RevertWhen_ReusingNonceSignature() public {
    bytes32 opId = keccak256(abi.encodePacked("op", uint256(5)));
    distributor.increaseUserClaimAmount(user1, 1000, IERC20(address(token)), opId);
    uint256 amountToClaim = distributor.amountToClaim(user1, IERC20(address(token)));
    uint256 half = amountToClaim / 2;

    (uint256 nonce, bytes memory sig) = _signClaim(user1, user2, half, address(token), user1Pk);

    // first claim works
    vm.prank(user2);
    distributor.claim(user1, user2, half, IERC20(address(token)), nonce, sig);

    // second claim with same nonce+sig should revert due to nonce consumed
    vm.prank(user2);
    vm.expectRevert(); // Nonce mismatch or checked nonce revert
    distributor.claim(user1, user2, half, IERC20(address(token)), nonce, sig);
  }

  function test_RevertWhen_NonAdminIncreasesClaim() public {
    vm.prank(user2);
    vm.expectRevert(bytes("RewardsDistributor: must have admin role"));
    distributor.increaseUserClaimAmount(user2, 1000, IERC20(address(token)), bytes32(0));
  }

  function test_RevertWhen_NonAdminAddsAdmin() public {
    vm.prank(user2);
    vm.expectRevert(bytes("RewardsDistributor: must have admin role"));
    distributor.addAdmin(user1);
  }

  function test_RevertWhen_NonAdminRemovesAdmin() public {
    assertTrue(distributor.isAdmin(deployer));
    vm.prank(user2);
    vm.expectRevert(bytes("RewardsDistributor: must have admin role"));
    distributor.removeAdmin(deployer);
  }

  function test_AdminAddRemoveAndIncreaseClaim() public {
    // add admin
    distributor.addAdmin(user1);
    assertTrue(distributor.isAdmin(user1));

    // as user1, increase claim for user2
    vm.prank(user1);
    bytes32 opId3 = keccak256(abi.encodePacked("op", uint256(4)));
    distributor.increaseUserClaimAmount(user2, 1000, IERC20(address(token)), opId3);
    assertEq(distributor.amountToClaim(user2, IERC20(address(token))), 1000);

    // remove admin
    distributor.removeAdmin(user1);
    assertFalse(distributor.isAdmin(user1));

    // now user1 cannot increase claim
    vm.prank(user1);
    vm.expectRevert(bytes("RewardsDistributor: must have admin role"));
    distributor.increaseUserClaimAmount(user2, 1000, IERC20(address(token)), bytes32(0));
  }

  function test_AdminWithdrawTokens() public {
    uint256 balContractBefore = token.balanceOf(address(distributor));
    uint256 balAdminBefore = token.balanceOf(deployer);
    assertGt(balContractBefore, 0);
    assertEq(balAdminBefore, 0);

    distributor.withdrawTokens(IERC20(address(token)), balContractBefore);

    uint256 balContractAfter = token.balanceOf(address(distributor));
    uint256 balAdminAfter = token.balanceOf(deployer);
    assertEq(balContractAfter, 0);
    assertEq(balAdminAfter, balContractBefore);
  }

  function test_RevertWhen_ReusingOperationId_Single() public {
    bytes32 opId = keccak256(abi.encodePacked("op", uint256(999)));
    distributor.increaseUserClaimAmount(user1, 123, IERC20(address(token)), opId);
    assertTrue(distributor.isOperationProcessed(opId));

    vm.expectRevert(bytes("RewardsDistributor: op already processed"));
    distributor.increaseUserClaimAmount(user1, 456, IERC20(address(token)), opId);
  }

  function test_RevertWhen_DuplicateOpIdInBatch() public {
    address[] memory users = new address[](2);
    users[0] = user1;
    users[1] = user2;
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 100;
    amounts[1] = 200;
    bytes32 dup = keccak256(abi.encodePacked("op", uint256(1001)));
    bytes32[] memory opIds = new bytes32[](2);
    opIds[0] = dup;
    opIds[1] = dup;

    vm.expectRevert(bytes("RewardsDistributor: op already processed"));
    distributor.increaseUsersClaimAmounts(users, amounts, IERC20(address(token)), opIds);
  }
}
