// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ReferralReward is Ownable, ReentrancyGuard {
    using safeERC20 for IERC20;

    IERC20 public immutable token;
    
    mapping(uint256 => bytes32) public merkleRoots;

    mapping(uint256 => mapping(uint256 => uint256)) public claimedBitMap;

    event MerkleRootUpdated(uint256 indexed epoch, bytes32 indexed merkleRoot);
    event RewardClaimed(uint256 indexed epoch, uint256 indexed index, adress indexed account, uint256 amount);
    event MerkleRootUpdated(uint256 indexed epoch, bytes32 merkleRoot);

    // TODO: check if we use custom errors or not.

    // error AlreadyClaimed();
    // error InvalidProof();
    // error TransferFailed();

    constructor(address _token) {
        require(_token != address(0), "Invalid token address");
        token = IERC20(_token);
    }

    function claim(uint256 epoch, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external nonReentrant {
        //TODO: check about gas sponsorship
        require(msg.sender == account, "Not authorized to claim");
        require(isClaimed(epoch, index) == false, "Already claimed");
        require(merkleRoots[epoch] != bytes32(0), "Merkle root not set");

        bytes32 node = keccak256(abi.encodePacked(index, account, amount));

        require(merkleProof.verify(merkleProof, merkleRoots[epoch], node), "Invalid proof");

        _setClaimed(epoch, index);

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
}


