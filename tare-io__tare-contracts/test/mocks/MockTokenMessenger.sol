// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITokenMessengerV2} from "contracts/interfaces/ITokenMessengerV2.sol";

/// @notice Records `depositForBurnWithHook` calls and pulls the burn amount like the real messenger.
contract MockTokenMessenger is ITokenMessengerV2 {
  uint256 public callCount;
  address public lastCaller;
  uint256 public lastAmount;
  uint32 public lastDestinationDomain;
  bytes32 public lastMintRecipient;
  address public lastBurnToken;
  bytes32 public lastDestinationCaller;
  uint256 public lastMaxFee;
  uint32 public lastMinFinalityThreshold;
  bytes public lastHookData;

  function depositForBurnWithHook(
    uint256 amount,
    uint32 destinationDomain,
    bytes32 mintRecipient,
    address burnToken,
    bytes32 destinationCaller,
    uint256 maxFee,
    uint32 minFinalityThreshold,
    bytes calldata hookData
  ) external {
    callCount++;
    lastCaller = msg.sender;
    lastAmount = amount;
    lastDestinationDomain = destinationDomain;
    lastMintRecipient = mintRecipient;
    lastBurnToken = burnToken;
    lastDestinationCaller = destinationCaller;
    lastMaxFee = maxFee;
    lastMinFinalityThreshold = minFinalityThreshold;
    lastHookData = hookData;

    require(IERC20(burnToken).transferFrom(msg.sender, address(this), amount), "pull failed");
  }
}

/// @notice Messenger that always reverts, to exercise the module's failure path.
contract RevertingTokenMessenger is ITokenMessengerV2 {
  function depositForBurnWithHook(
    uint256,
    uint32,
    bytes32,
    address,
    bytes32,
    uint256,
    uint32,
    bytes calldata
  ) external pure {
    revert("messenger reverted");
  }
}
