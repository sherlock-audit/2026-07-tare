// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LoansAuth} from "contracts/misc/LoansAuth.sol";
import {ILoansAuth} from "contracts/misc/interfaces/ILoansAuth.sol";
import {Roles} from "contracts/interfaces/ILoans.sol";

contract LoansAuthHarness is LoansAuth {
  constructor(address initialGuardian) LoansAuth(initialGuardian) {}
}

contract LoansAuthTest is Test {
  address internal guardian = makeAddr("guardian");
  address internal admin = makeAddr("admin");
  address internal originator = makeAddr("originator");
  address internal borrower = makeAddr("borrower");
  address internal randomUser = makeAddr("randomUser");

  LoansAuthHarness internal auth;
  bytes32 internal ADMIN_ROLE_;
  bytes32 internal GUARDIAN_ROLE_;

  function setUp() public {
    auth = new LoansAuthHarness(guardian);
    ADMIN_ROLE_ = auth.ADMIN_ROLE();
    GUARDIAN_ROLE_ = auth.GUARDIAN_ROLE();
    vm.prank(guardian);
    auth.grantRole(ADMIN_ROLE_, admin);
  }

  function test_ApproveOriginator_SetsRoleAndEmitsOriginatorApproved() public {
    assertEq(auth.addressBook(address(auth), originator), 0);

    vm.prank(guardian);
    vm.expectEmit(true, true, false, true);
    emit ILoansAuth.OriginatorApproved(originator);
    auth.approveOriginator(originator);

    assertEq(auth.addressBook(address(auth), originator), auth.ORIGINATOR_MASK());
    assertTrue(auth.isRegisteredForRole(address(auth), Roles.Originator, originator));
  }

  function test_ApproveOriginator_RevertsWhenCallerNotGuardian() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, GUARDIAN_ROLE_)
    );
    auth.approveOriginator(originator);
  }

  function test_ApproveOriginator_WorksWhenGrantedToAlreadyAdmin() public {
    vm.prank(guardian);
    auth.approveOriginator(admin);

    assertEq(auth.addressBook(address(auth), admin), auth.ORIGINATOR_MASK());
    assertTrue(auth.isRegisteredForRole(address(auth), Roles.Originator, admin));
  }

  function test_RevokeOriginator_ResetsRoleAndEmitsOriginatorRevoked() public {
    vm.prank(guardian);
    auth.approveOriginator(originator);

    vm.prank(admin);
    vm.expectEmit(true, false, false, true);
    emit ILoansAuth.OriginatorRevoked(originator);
    auth.revokeOriginator(originator);

    assertEq(auth.addressBook(address(auth), originator), 0);
    assertFalse(auth.isRegisteredForRole(address(auth), Roles.Originator, originator));
  }

  function test_RevokeOriginator_RevertsWhenCallerNotAdmin() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, ADMIN_ROLE_)
    );
    auth.revokeOriginator(originator);
  }

  function test_RevokeOriginator_NoOpWhenTargetNotApprovedOriginator() public {
    vm.prank(admin);
    auth.revokeOriginator(randomUser);
    assertEq(auth.addressBook(address(auth), randomUser), 0);
  }

  // ========== Servicer Approval Tests ==========

  function test_ApproveServicer_SetsRoleAndEmitsServicerApproved() public {
    address servicer = makeAddr("servicer");

    vm.prank(guardian);
    vm.expectEmit(true, false, false, true);
    emit ILoansAuth.ServicerApproved(servicer);
    auth.approveServicer(servicer);

    assertTrue(auth.isRegisteredForRole(address(auth), Roles.Servicer, servicer));
  }

  function test_ApproveServicer_RevertsWhenCallerNotGuardian() public {
    address servicer = makeAddr("servicer");

    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, GUARDIAN_ROLE_)
    );
    auth.approveServicer(servicer);
  }

  function test_RevokeServicer_ResetsRoleAndEmitsServicerRevoked() public {
    address servicer = makeAddr("servicer");

    vm.prank(guardian);
    auth.approveServicer(servicer);
    assertTrue(auth.isRegisteredForRole(address(auth), Roles.Servicer, servicer));

    vm.prank(admin);
    vm.expectEmit(true, false, false, true);
    emit ILoansAuth.ServicerRevoked(servicer);
    auth.revokeServicer(servicer);

    assertFalse(auth.isRegisteredForRole(address(auth), Roles.Servicer, servicer));
  }

  function test_RevokeServicer_RevertsWhenCallerNotAdmin() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, ADMIN_ROLE_)
    );
    auth.revokeServicer(makeAddr("servicer"));
  }

  // ========== Address Book Tests ==========

  function test_RegisterAddress_SetsRoleAndEmitsEvent() public {
    vm.prank(originator);
    vm.expectEmit(true, true, false, true);
    emit ILoansAuth.AddressRegistered(originator, Roles.Borrower, borrower);
    auth.registerAddress(Roles.Borrower, borrower);

    assertTrue(auth.isRegisteredForRole(originator, Roles.Borrower, borrower));
  }

  function test_UnregisterAddress_ClearsRoleAndEmitsEvent() public {
    vm.startPrank(originator);
    auth.registerAddress(Roles.Borrower, borrower);

    vm.expectEmit(true, true, false, true);
    emit ILoansAuth.AddressUnregistered(originator, Roles.Borrower, borrower);
    auth.unregisterAddress(Roles.Borrower, borrower);
    vm.stopPrank();

    assertFalse(auth.isRegisteredForRole(originator, Roles.Borrower, borrower));
  }

  function test_RegisterAddress_BitmaskSupportsMultipleRoles() public {
    address multiRoleAddr = makeAddr("multiRole");

    vm.startPrank(originator);
    auth.registerAddress(Roles.Originator, multiRoleAddr);
    auth.registerAddress(Roles.Investor, multiRoleAddr);
    vm.stopPrank();

    assertTrue(auth.isRegisteredForRole(originator, Roles.Originator, multiRoleAddr));
    assertTrue(auth.isRegisteredForRole(originator, Roles.Investor, multiRoleAddr));

    // Unregister one role, other should remain
    vm.prank(originator);
    auth.unregisterAddress(Roles.Originator, multiRoleAddr);

    assertFalse(auth.isRegisteredForRole(originator, Roles.Originator, multiRoleAddr));
    assertTrue(auth.isRegisteredForRole(originator, Roles.Investor, multiRoleAddr));
  }

  function test_AddressBook_IsolatedBetweenOwners() public {
    address sharedAddr = makeAddr("sharedAddr");
    address originatorB = makeAddr("originatorB");

    // Register sharedAddr in originator's book only
    vm.prank(originator);
    auth.registerAddress(Roles.Borrower, sharedAddr);

    // Should be registered for originator but NOT for originatorB
    assertTrue(auth.isRegisteredForRole(originator, Roles.Borrower, sharedAddr));
    assertFalse(auth.isRegisteredForRole(originatorB, Roles.Borrower, sharedAddr));

    // Now register in originatorB's book
    vm.prank(originatorB);
    auth.registerAddress(Roles.Investor, sharedAddr);

    // Each book should only have their own registration for a different role
    assertTrue(auth.isRegisteredForRole(originator, Roles.Borrower, sharedAddr));
    assertFalse(auth.isRegisteredForRole(originator, Roles.Investor, sharedAddr));

    assertFalse(auth.isRegisteredForRole(originatorB, Roles.Borrower, sharedAddr));
    assertTrue(auth.isRegisteredForRole(originatorB, Roles.Investor, sharedAddr));
  }

  // ========== OnBehalfOf Address Book Tests ==========

  function test_RegisterAddressOnBehalfOf_AdminCanRegister() public {
    address targetOwner = makeAddr("targetOwner");

    vm.prank(admin);
    vm.expectEmit(true, true, false, true);
    emit ILoansAuth.AddressRegistered(targetOwner, Roles.Borrower, borrower);
    auth.registerAddressOnBehalfOf(targetOwner, Roles.Borrower, borrower);

    assertTrue(auth.isRegisteredForRole(targetOwner, Roles.Borrower, borrower));
  }

  function test_RegisterAddressOnBehalfOf_GuardianCanRegister() public {
    address targetOwner = makeAddr("targetOwner");

    vm.prank(guardian);
    vm.expectEmit(true, true, false, true);
    emit ILoansAuth.AddressRegistered(targetOwner, Roles.Investor, borrower);
    auth.registerAddressOnBehalfOf(targetOwner, Roles.Investor, borrower);

    assertTrue(auth.isRegisteredForRole(targetOwner, Roles.Investor, borrower));
  }

  function test_RegisterAddressOnBehalfOf_RevertsWhenCallerNotAdminOrGuardian() public {
    address targetOwner = makeAddr("targetOwner");

    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, ADMIN_ROLE_)
    );
    auth.registerAddressOnBehalfOf(targetOwner, Roles.Borrower, borrower);
  }

  function test_RegisterAddressOnBehalfOf_RevertsWhenOwnerIsContractItself() public {
    vm.prank(admin);
    vm.expectRevert(ILoansAuth.InvalidAddressBookOwner.selector);
    auth.registerAddressOnBehalfOf(address(auth), Roles.Borrower, borrower);
  }

  function test_UnregisterAddressOnBehalfOf_ClearsRoleAndEmitsEvent() public {
    address targetOwner = makeAddr("targetOwner");

    vm.startPrank(admin);
    auth.registerAddressOnBehalfOf(targetOwner, Roles.Borrower, borrower);
    assertTrue(auth.isRegisteredForRole(targetOwner, Roles.Borrower, borrower));

    vm.expectEmit(true, true, false, true);
    emit ILoansAuth.AddressUnregistered(targetOwner, Roles.Borrower, borrower);
    auth.unregisterAddressOnBehalfOf(targetOwner, Roles.Borrower, borrower);
    vm.stopPrank();

    assertFalse(auth.isRegisteredForRole(targetOwner, Roles.Borrower, borrower));
  }

  function test_UnregisterAddressOnBehalfOf_GuardianCanUnregister() public {
    address targetOwner = makeAddr("targetOwner");

    vm.prank(admin);
    auth.registerAddressOnBehalfOf(targetOwner, Roles.Originator, borrower);

    vm.prank(guardian);
    auth.unregisterAddressOnBehalfOf(targetOwner, Roles.Originator, borrower);

    assertFalse(auth.isRegisteredForRole(targetOwner, Roles.Originator, borrower));
  }

  function test_UnregisterAddressOnBehalfOf_RevertsWhenCallerNotAdminOrGuardian() public {
    address targetOwner = makeAddr("targetOwner");

    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, ADMIN_ROLE_)
    );
    auth.unregisterAddressOnBehalfOf(targetOwner, Roles.Borrower, borrower);
  }

  function test_UnregisterAddressOnBehalfOf_RevertsWhenOwnerIsContractItself() public {
    vm.prank(admin);
    vm.expectRevert(ILoansAuth.InvalidAddressBookOwner.selector);
    auth.unregisterAddressOnBehalfOf(address(auth), Roles.Borrower, borrower);
  }

  function test_UnregisterAddressOnBehalfOf_NoOpWhenNotPreviouslyRegistered() public {
    address targetOwner = makeAddr("targetOwner");

    assertFalse(auth.isRegisteredForRole(targetOwner, Roles.Borrower, borrower));

    vm.prank(admin);
    auth.unregisterAddressOnBehalfOf(targetOwner, Roles.Borrower, borrower);

    assertFalse(auth.isRegisteredForRole(targetOwner, Roles.Borrower, borrower));
  }
}
