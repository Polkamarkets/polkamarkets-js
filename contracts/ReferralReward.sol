// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract ReferralReward is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token;

    mapping(uint256 => bytes32) public merkleRoots;

    /*
     * @notice: Instead of storing mapping(uint256 => mapping(uint256 => address)),
     * we only store a bit (0/1) per claim.
     * Each uint256 stores 256 claims → massive storage savings.
     * Cheap to read (SLOAD) and write (SSTORE).
     */

    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitMap;

    event MerkleRootUpdated(uint256 indexed epoch, bytes32 indexed merkleRoot);
    event RewardClaimed(uint256 indexed epoch, uint256 indexed index, address indexed account, uint256 amount);

    constructor() {}

    function claim(
        uint256 epoch,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        require(msg.sender == account, "Not authorized to claim");
        require(isClaimed(epoch, index) == false, "Already claimed");
        require(merkleRoots[epoch] != bytes32(0), "Merkle root not set");

        bytes32 node = keccak256(abi.encodePacked(index, account, amount));

        require(MerkleProof.verify(merkleProof, merkleRoots[epoch], node), "Invalid proof");

        _setClaimed(epoch, index);

        token.safeTransfer(account, amount);

        emit RewardClaimed(epoch, index, account, amount);
    }

    function updateMerkleRoot(uint256 epoch, bytes32 merkleRoot) external onlyOwner {
        require(merkleRoots[epoch] == bytes32(0), "Merkle root already set");
        merkleRoots[epoch] = merkleRoot;
        emit MerkleRootUpdated(epoch, merkleRoot);
    }

    /**
     * @notice Check if a claim at a given index in a given epoch has already been made.
     * @param epoch Epoch ID.
     * @param index Index in Merkle tree.
     * @return claimed True if claimed.
     */
    function isClaimed(uint256 epoch, uint256 index) public view returns (bool claimed) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 word = claimedBitMap[epoch][wordIndex];
        uint256 mask = 1 << bitIndex;
        claimed = (word & mask) == mask;
    }

    function _setClaimed(uint256 epoch, uint256 index) internal {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitMap[epoch][wordIndex] = claimedBitMap[epoch][wordIndex] | (1 << bitIndex);
    }

    function setRewardToken(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        token = IERC20(_token);
    }

    /* @notice: Withdraw tokens from contract
     * just in case if there is some token stuck in contract
     */

    function withdrawERC20(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function withdrawETH(address payable _to) external onlyOwner {
        require(_to != address(0), "Invalid recipient");
        (bool success, ) = _to.call{value: address(this).balance}("");
        require(success, "Withdraw failed");
    }
}
