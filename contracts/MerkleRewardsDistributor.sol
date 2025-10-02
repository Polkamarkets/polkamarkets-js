// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OpenZeppelin upgradeable
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// OpenZeppelin non-upgradeable utils
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title Merkle-based rewards distributor for contests
/// @notice Owner publishes one Merkle root per (contestId, token). Users claim with proof.
contract MerkleRewardsDistributor is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
  using SafeERC20 for IERC20;

  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

  // rootKey => merkleRoot
  mapping(bytes32 => bytes32) private _roots;
  // rootKey => claimed bitmap wordIndex => word
  mapping(bytes32 => mapping(uint256 => uint256)) private _claimedBitMap;

  event RootPublished(string contestId, IERC20 indexed token, bytes32 indexed root, bytes32 indexed rootKey);
  event Claimed(
    string contestId,
    IERC20 indexed token,
    uint256 indexed index,
    address indexed account,
    uint256 amount
  );
  event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address initialOwner) public initializer {
    __ReentrancyGuard_init();
    __Ownable_init(initialOwner);
    __UUPSUpgradeable_init();
    __AccessControl_init();

    _grantRole(ADMIN_ROLE, initialOwner);
    _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  // ------ Admin ------

  /// @notice Publishes/updates the root for a given (contestId, token)
  function publishRoot(string calldata contestId, IERC20 token, bytes32 root) external onlyAdmin {
    bytes32 key = _rootKey(contestId, token);
    _roots[key] = root;
    emit RootPublished(contestId, token, root, key);
  }

  function withdraw(IERC20 token, uint256 amount) external onlyOwner nonReentrant {
    token.safeTransfer(msg.sender, amount);
    emit TokensWithdrawn(address(token), msg.sender, amount);
  }

  // role management
  modifier onlyAdmin() {
    require(hasRole(ADMIN_ROLE, msg.sender), "MerkleRewards: must have admin role");
    _;
  }

  function addAdmin(address account) external onlyAdmin {
    grantRole(ADMIN_ROLE, account);
  }

  function removeAdmin(address account) external onlyAdmin {
    revokeRole(ADMIN_ROLE, account);
  }

  function isAdmin(address account) external view returns (bool) {
    return hasRole(ADMIN_ROLE, account);
  }

  // ------ Claims ------

  /// @notice Claims `amount` for `account` with a Merkle proof. Funds are sent to `account`.
  /// @dev Leaf is keccak256(abi.encode(index, account, token, amount, contestId))
  function claim(
    string calldata contestId,
    IERC20 token,
    uint256 index,
    address account,
    uint256 amount,
    bytes32[] calldata merkleProof
  ) external nonReentrant {
    bytes32 key = _rootKey(contestId, token);
    bytes32 root = _roots[key];
    require(root != bytes32(0), "MerkleRewards: root not set");
    require(!_isClaimed(key, index), "MerkleRewards: already claimed");

    bytes32 leaf = keccak256(abi.encode(index, account, token, amount, contestId));
    require(MerkleProof.verify(merkleProof, root, leaf), "MerkleRewards: invalid proof");

    _setClaimed(key, index);

    token.safeTransfer(account, amount);

    emit Claimed(contestId, token, index, account, amount);
  }

  /// @notice Claims multiple entries in one transaction. Funds are sent to each entry's `account`.
  function claimMany(
    string[] calldata contestIds,
    IERC20[] calldata tokens,
    uint256[] calldata indices,
    address[] calldata accounts,
    uint256[] calldata amounts,
    bytes32[][] calldata merkleProofs
  ) external nonReentrant {
    uint256 len = contestIds.length;
    require(
      len == tokens.length &&
      len == indices.length &&
      len == accounts.length &&
      len == amounts.length &&
      len == merkleProofs.length,
      "MerkleRewards: arrays length mismatch"
    );

    for (uint256 i = 0; i < len; i++) {
      bytes32 key = _rootKey(contestIds[i], tokens[i]);
      bytes32 root = _roots[key];
      require(root != bytes32(0), "MerkleRewards: root not set");
      require(!_isClaimed(key, indices[i]), "MerkleRewards: already claimed");

      bytes32 leaf = keccak256(abi.encode(indices[i], accounts[i], tokens[i], amounts[i], contestIds[i]));
      require(MerkleProof.verify(merkleProofs[i], root, leaf), "MerkleRewards: invalid proof");

      _setClaimed(key, indices[i]);
      tokens[i].safeTransfer(accounts[i], amounts[i]);

      emit Claimed(contestIds[i], tokens[i], indices[i], accounts[i], amounts[i]);
    }
  }

  // ------ Views ------

  function getRoot(string calldata contestId, IERC20 token) external view returns (bytes32) {
    return _roots[_rootKey(contestId, token)];
  }

  function isClaimed(
    string calldata contestId,
    IERC20 token,
    uint256 index
  ) external view returns (bool) {
    return _isClaimed(_rootKey(contestId, token), index);
  }

  function isClaimedMany(
    string[] calldata contestIds,
    IERC20[] calldata tokens,
    uint256[] calldata indices
  ) external view returns (bool[] memory) {
    bool[] memory claims = new bool[](contestIds.length);
    for (uint256 i = 0; i < contestIds.length; i++) {
      claims[i] = _isClaimed(_rootKey(contestIds[i], tokens[i]), indices[i]);
    }
    return claims;
  }

  // ------ Internal utils ------

  function _rootKey(string calldata contestId, IERC20 token) private pure returns (bytes32) {
    return keccak256(abi.encode(contestId, token));
  }

  function _isClaimed(bytes32 key, uint256 index) private view returns (bool) {
    uint256 wordIndex = index >> 8; // divide by 256
    uint256 bitIndex = index & 255; // modulo 256
    uint256 word = _claimedBitMap[key][wordIndex];
    uint256 mask = (1 << bitIndex);
    return word & mask == mask;
  }

  function _setClaimed(bytes32 key, uint256 index) private {
    uint256 wordIndex = index >> 8;
    uint256 bitIndex = index & 255;
    _claimedBitMap[key][wordIndex] = _claimedBitMap[key][wordIndex] | (1 << bitIndex);
  }
}
