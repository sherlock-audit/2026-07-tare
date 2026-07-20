// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721Utils} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Utils.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ILoansNFT, ILockable} from "contracts/interfaces/ILoansNFT.sol";
import {IGuardianAccessControl} from "contracts/misc/interfaces/IGuardianAccessControl.sol";

/**
 * @title LoansNFT
 * @notice ERC721Enumerable loan NFT with ERC-5753-compatible locking.
 */
contract LoansNFT is ILoansNFT, ERC721Enumerable {
  address public immutable LOANS_CONTRACT;

  /// @dev Cached from the Loans contract to avoid repeated external calls.
  bytes32 public immutable ADMIN_ROLE;

  /// @dev Cached from the Loans contract to avoid repeated external calls.
  bytes32 public immutable GUARDIAN_ROLE;

  string private _loansBaseURI;
  mapping(uint256 tokenId => address unlocker) private _unlockers;

  /// @inheritdoc ILoansNFT
  mapping(address account => uint256 nonce) public ownershipNonce;

  constructor(
    address loansContract,
    string memory collectionName,
    string memory baseURI
  ) ERC721(collectionName, "LOAN") {
    require(loansContract != address(0), Unauthorized());
    LOANS_CONTRACT = loansContract;
    ADMIN_ROLE = IGuardianAccessControl(loansContract).ADMIN_ROLE();
    GUARDIAN_ROLE = IGuardianAccessControl(loansContract).GUARDIAN_ROLE();
    _loansBaseURI = baseURI;
    emit BaseURIUpdated(baseURI);
  }

  /// @inheritdoc ILoansNFT
  function mint(address to, uint256 tokenId) external {
    require(msg.sender == LOANS_CONTRACT, Unauthorized());

    _mint(to, tokenId);
  }

  /// @inheritdoc ILoansNFT
  function setBaseURI(string calldata newBaseURI) external {
    require(IGuardianAccessControl(LOANS_CONTRACT).hasRole(ADMIN_ROLE, msg.sender), Unauthorized());

    _loansBaseURI = newBaseURI;
    emit BaseURIUpdated(newBaseURI);
  }

  /// @inheritdoc ILoansNFT
  function forceTransfer(address from, address to, uint256 tokenId) external {
    require(IGuardianAccessControl(LOANS_CONTRACT).hasRole(GUARDIAN_ROLE, msg.sender), Unauthorized());

    address currentOwner = _requireOwned(tokenId);
    require(from == currentOwner, InvalidFrom());
    require(to != address(0), InvalidTo());
    require(_unlockers[tokenId] == address(0), TokenLocked());

    // Pass `address(0)` as `auth` to bypass the ERC721 approval check. The
    // override still runs (bumping ownership nonces and emitting `Transfer`).
    _update(to, tokenId, address(0));

    // Ensure `to` can receive ERC-721s, mirroring the safe-transfer rescue path.
    ERC721Utils.checkOnERC721Received(msg.sender, from, to, tokenId, "");

    emit ForceTransfer(from, to, tokenId);
  }

  /**
   * @inheritdoc ILockable
   * @dev Authorization is intentionally broader than the ERC-5753 reference
   *      implementation (owner or operator): per-token approved addresses may also
   *      lock. This lets integrators such as `LoansExchange` lock listed loans with
   *      narrow per-token approvals instead of requiring `setApprovalForAll`.
   */
  function lock(address unlocker, uint256 id) external {
    address tokenOwner = ownerOf(id);

    require(unlocker != address(0), InvalidUnlocker());
    require(_unlockers[id] == address(0), AlreadyLocked());
    require(_isAuthorized(tokenOwner, msg.sender, id), Unauthorized());

    // Clear approval
    _approve(address(0), id, address(0), false);
    _unlockers[id] = unlocker;

    emit Lock(unlocker, id);
  }

  /// @inheritdoc ILockable
  function unlock(uint256 id) external {
    _requireOwned(id);
    require(msg.sender == _unlockers[id], NotUnlocker());

    delete _unlockers[id];

    emit Unlock(id);
  }

  /// @inheritdoc ILockable
  function getLocked(uint256 tokenId) public view returns (address unlocker) {
    _requireOwned(tokenId);
    return _unlockers[tokenId];
  }

  /// @inheritdoc ILoansNFT
  function ownerAndUnlocker(uint256 tokenId) external view returns (address owner, address unlocker) {
    owner = _requireOwned(tokenId);
    unlocker = _unlockers[tokenId];
  }

  /// @inheritdoc ERC721
  function approve(address to, uint256 tokenId) public override(ERC721, IERC721) {
    require(_unlockers[tokenId] == address(0), TokenLocked());
    super.approve(to, tokenId);
  }

  /// @inheritdoc ERC721
  function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
    _requireOwned(tokenId);

    address unlocker = _unlockers[tokenId];
    if (unlocker != address(0)) {
      return unlocker;
    }

    return super._getApproved(tokenId);
  }

  /**
   * @inheritdoc IERC165
   * @dev Advertises `ILockable` (ERC-5753) support in addition to the standard ERC721 set.
   */
  function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable, IERC165) returns (bool) {
    return interfaceId == type(ILockable).interfaceId || super.supportsInterface(interfaceId);
  }

  /**
   * @dev Returns the base URI prefix used by `tokenURI`. Settable by admin via `setBaseURI`.
   */
  function _baseURI() internal view override returns (string memory) {
    return _loansBaseURI;
  }

  /// @inheritdoc ERC721Enumerable
  function _update(address to, uint256 tokenId, address auth) internal override returns (address previousOwner) {
    address unlocker = _unlockers[tokenId];
    address from = _ownerOf(tokenId);

    bool isLocked = from != address(0) && unlocker != address(0);
    if (isLocked && auth != unlocker) {
      revert TokenLocked();
    }

    // Bump per-address ownership nonce so external integrators can detect any
    // change to the NFT ownership set of a given address. The zero address is
    // skipped (mint's `from`, burn's `to`) because no consumer reads that slot.
    unchecked {
      if (from != address(0)) ++ownershipNonce[from];
      if (to != address(0)) ++ownershipNonce[to];
    }

    // When the unlocker is transferring a locked token, bypass the standard
    // ERC-721 approval check (pass address(0) as auth) because the unlocker
    // is not set via the normal approve() storage slot.
    previousOwner = super._update(to, tokenId, isLocked ? address(0) : auth);

    if (previousOwner != address(0) && unlocker != address(0)) {
      delete _unlockers[tokenId];
      emit Unlock(tokenId);
    }
  }
}
