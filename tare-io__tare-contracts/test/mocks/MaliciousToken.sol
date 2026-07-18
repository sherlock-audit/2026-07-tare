// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Loans} from "src/Loans.sol";

/// @notice Malicious ERC20 token that attempts reentrancy on transferFrom
contract MaliciousToken {
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  address public loansContract;
  uint64 public loanId;
  bool public attackTriggered;

  function setLoansContract(address _loans) external {
    loansContract = _loans;
  }

  function setLoanId(uint64 _loanId) external {
    loanId = _loanId;
  }

  function mint(address to, uint256 amount) external {
    balanceOf[to] += amount;
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    allowance[from][msg.sender] -= amount;
    balanceOf[from] -= amount;
    balanceOf[to] += amount;

    // Attempt reentrancy attack
    if (!attackTriggered && loansContract != address(0)) {
      attackTriggered = true;
      // Try to call fund again
      Loans(loansContract).fund(loanId, int128(int256(amount)), uint48(block.timestamp), bytes32("reentrant"));
    }

    return true;
  }
}
