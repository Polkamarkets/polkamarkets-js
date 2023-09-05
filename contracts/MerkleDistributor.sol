// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MerkleDistributor {
    address public immutable token;
    address public immutable owner;
    bytes32 public merkleRoot;
    uint32 public week;
    bool public frozen;

    // This is a packed array of booleans.
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;

	  // Total claimed for receiver addresses. for informational purposes only
    mapping(address => uint256) public totalClaimed;

    // This event is triggered whenever a call to #claim succeeds.
    event Claimed(uint256 index, uint256 amount, address indexed tokenReceiver, uint256 indexed week);

    // This event is triggered whenever the merkle root gets updated.
    event MerkleRootUpdated(bytes32 indexed merkleRoot, uint32 indexed week);

    modifier onlyOwner() {
        require(msg.sender == owner, "MerkleDistributor: Only owner can do this action");
        _;
    }

    constructor(address token_,address owner_, bytes32 merkleRoot_) public {
        require(token_ != address(0), "MerkleDistributor: invalid token");
        token = token_;
        owner = owner_;
        merkleRoot = merkleRoot_;
        week = 0;
        frozen = false;
    }

    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external {
        require(!frozen, "MerkleDistributor: Claiming is frozen.");
        require(!isClaimed(index), "MerkleDistributor: already claimed.");

        _claim(index, account, amount, merkleProof);
    }

    function isClaimed(uint256 index) public view returns (bool) {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        uint256 claimedWord = claimedBitMap[week][claimedWordIndex];
        uint256 mask = (1 << claimedBitIndex);
        return claimedWord & mask == mask;
    }

    function freeze() public onlyOwner {
        frozen = true;
    }

    function unfreeze() public onlyOwner {
        frozen = false;
    }

    function updateMerkleRoot(bytes32 _merkleRoot) public onlyOwner {
        require(frozen, "MerkleDistributor: Contract not frozen.");

        // Increment the week (simulates the clearing of the claimedBitMap)
        week = week + 1;
        // Set the new merkle root
        merkleRoot = _merkleRoot;

        emit MerkleRootUpdated(merkleRoot, week);
    }

    function _claim(uint256 index, address tokenReceiver, uint256 amount, bytes32[] calldata merkleProof) internal {
        // Verify the merkle proof.
        bytes32 node = keccak256(abi.encodePacked(index, tokenReceiver, amount));
        require(MerkleProof.verify(merkleProof, merkleRoot, node), "MerkleDistributor: Invalid proof.");

        // Mark it claimed and send the token.
        _setClaimed(index);
        require(IERC20(token).transfer(tokenReceiver, amount), "MerkleDistributor: Transfer failed.");

		    totalClaimed[tokenReceiver] += amount;

        emit Claimed(index, amount, tokenReceiver, week);
    }

    function _setClaimed(uint256 index) private {
        uint256 claimedWordIndex = index / 256;
        uint256 claimedBitIndex = index % 256;
        claimedBitMap[week][claimedWordIndex] = claimedBitMap[week][claimedWordIndex] | (1 << claimedBitIndex);
    }
}