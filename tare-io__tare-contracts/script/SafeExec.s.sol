// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {ISafe} from "../contracts/misc/interfaces/ISafe.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";

contract SafeExec is Script {
  function run() public {
    address safeAddress = vm.envAddress("SAFE_ADDRESS");
    address targetAddress = vm.envAddress("TARGET_ADDRESS");
    bytes memory callData = vm.envBytes("CALL_DATA");

    ISafe safe = ISafe(safeAddress);
    // Fail early and return friendlier error message if caller is not an owner of the Safe
    require(safe.isOwner(msg.sender), "SafeExec: caller is not a Safe owner");
    require(
      safe.getThreshold() == 1,
      "SafeExec: multi-sig Safes (threshold > 1) are not supported; use the Safe Transaction Service"
    );

    uint256 nonce = safe.nonce();

    bytes32 txHash = safe.getTransactionHash(
      targetAddress,
      0,
      callData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      address(0),
      nonce
    );

    vm.startBroadcast();

    safe.approveHash(txHash);

    address sender = msg.sender;
    bytes memory signature = abi.encodePacked(bytes12(0), bytes20(sender), bytes32(0), uint8(1));

    bool success = safe.execTransaction(
      targetAddress,
      0,
      callData,
      Enum.Operation.Call,
      0,
      0,
      0,
      address(0),
      payable(address(0)),
      signature
    );
    require(success, "Safe transaction failed");

    vm.stopBroadcast();
  }
}
