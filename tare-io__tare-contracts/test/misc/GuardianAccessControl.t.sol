// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {GuardianAccessControl} from "contracts/misc/GuardianAccessControl.sol";
import {IGuardianAccessControl} from "contracts/misc/interfaces/IGuardianAccessControl.sol";

contract GuardianAccessControlHarness is GuardianAccessControl {
  constructor(address initialGuardian) {
    _initGuardian(initialGuardian);
  }

  function exposed_isAdminOrGuardian(address account) external view returns (bool) {
    return _isAdminOrGuardian(account);
  }
}

contract GuardianAccessControlInitTest is Test {
  function test_Constructor_RevertsWhenInitialGuardianZero() public {
    vm.expectRevert(IGuardianAccessControl.InvalidGuardian.selector);
    new GuardianAccessControlHarness(address(0));
  }

  function test_Constructor_GrantsGuardianRoleAndLocksRoleHierarchy() public {
    address guardian = makeAddr("guardian");
    GuardianAccessControlHarness control = new GuardianAccessControlHarness(guardian);

    bytes32 guardianRole = control.GUARDIAN_ROLE();
    bytes32 adminRole = control.ADMIN_ROLE();
    bytes32 pauserRole = control.PAUSER_ROLE();
    bytes32 defaultAdminRole = control.DEFAULT_ADMIN_ROLE();

    assertTrue(control.hasRole(guardianRole, guardian));
    // Guardian is the role-admin for all roles, including DEFAULT_ADMIN_ROLE.
    // Without this lock-down, DEFAULT_ADMIN_ROLE would be self-admining (bytes32(0))
    // and any holder could escalate to any role.
    assertEq(control.getRoleAdmin(defaultAdminRole), guardianRole);
    assertEq(control.getRoleAdmin(guardianRole), guardianRole);
    assertEq(control.getRoleAdmin(adminRole), guardianRole);
    assertEq(control.getRoleAdmin(pauserRole), guardianRole);
  }
}

contract GuardianAccessControlTest is Test {
  GuardianAccessControlHarness internal control;

  address internal guardian = makeAddr("guardian");
  address internal admin = makeAddr("admin");
  address internal pauser = makeAddr("pauser");
  address internal randomUser = makeAddr("randomUser");

  bytes32 internal GUARDIAN_ROLE_;
  bytes32 internal ADMIN_ROLE_;
  bytes32 internal PAUSER_ROLE_;

  function setUp() public {
    control = new GuardianAccessControlHarness(guardian);
    GUARDIAN_ROLE_ = control.GUARDIAN_ROLE();
    ADMIN_ROLE_ = control.ADMIN_ROLE();
    PAUSER_ROLE_ = control.PAUSER_ROLE();

    vm.prank(guardian);
    control.grantRole(ADMIN_ROLE_, admin);

    vm.prank(guardian);
    control.grantRole(PAUSER_ROLE_, pauser);
  }

  // ========== setRoleAdmin ==========

  function test_SetRoleAdmin_GuardianCanChangeRoleAdmin() public {
    bytes32 newAdminRole = keccak256("CUSTOM_ROLE");

    vm.prank(guardian);
    control.setRoleAdmin(ADMIN_ROLE_, newAdminRole);

    assertEq(control.getRoleAdmin(ADMIN_ROLE_), newAdminRole);
  }

  function test_SetRoleAdmin_RevertsWhenRoleIsGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(IGuardianAccessControl.CannotChangeGuardianAdmin.selector);
    control.setRoleAdmin(GUARDIAN_ROLE_, keccak256("OTHER"));
  }

  function test_SetRoleAdmin_RevertsWhenCallerNotGuardian() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, GUARDIAN_ROLE_)
    );
    control.setRoleAdmin(ADMIN_ROLE_, keccak256("OTHER"));
  }

  // ========== pause ==========

  function test_Pause_AdminCanPause() public {
    vm.prank(admin);
    control.pause();
    assertTrue(control.paused());
  }

  function test_Pause_GuardianCanPause() public {
    vm.prank(guardian);
    control.pause();
    assertTrue(control.paused());
  }

  function test_Pause_PauserCanPause() public {
    vm.prank(pauser);
    control.pause();
    assertTrue(control.paused());
  }

  function test_Pause_RevertsWhenCallerHasNoRole() public {
    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, PAUSER_ROLE_)
    );
    control.pause();
  }

  // ========== unpause ==========

  function test_Unpause_GuardianCanUnpause() public {
    vm.prank(guardian);
    control.pause();

    vm.prank(guardian);
    control.unpause();

    assertFalse(control.paused());
  }

  // Admin can pause but NOT unpause: unpause is guardian-only by design.
  function test_Unpause_RevertsWhenCallerIsAdminOnly() public {
    vm.prank(guardian);
    control.pause();

    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, GUARDIAN_ROLE_)
    );
    control.unpause();
  }

  function test_Unpause_RevertsWhenCallerHasNeitherRole() public {
    vm.prank(guardian);
    control.pause();

    vm.prank(randomUser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, GUARDIAN_ROLE_)
    );
    control.unpause();
  }

  // ========== PAUSER_ROLE least-privilege ==========

  // Pauser must not be able to undo a pause: unpause stays guardian-only.
  function test_Unpause_RevertsWhenCallerIsPauserOnly() public {
    vm.prank(pauser);
    control.pause();

    vm.prank(pauser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, GUARDIAN_ROLE_)
    );
    control.unpause();
  }

  function test_SetRoleAdmin_RevertsWhenCallerIsPauserOnly() public {
    vm.prank(pauser);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, GUARDIAN_ROLE_)
    );
    control.setRoleAdmin(ADMIN_ROLE_, keccak256("OTHER"));
  }

  function test_GrantRole_AdminCannotGrantPauserRole() public {
    address newPauser = makeAddr("newPauser");

    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, GUARDIAN_ROLE_)
    );
    control.grantRole(PAUSER_ROLE_, newPauser);
  }

  function test_RevokeRole_GuardianCanRevokePauserRole() public {
    vm.prank(guardian);
    control.revokeRole(PAUSER_ROLE_, pauser);

    assertFalse(control.hasRole(PAUSER_ROLE_, pauser));
  }

  // ========== renounceRole ==========

  function test_RenounceRole_RevertsForGuardianRole() public {
    vm.prank(guardian);
    vm.expectRevert(IGuardianAccessControl.RenounceRoleDisabled.selector);
    control.renounceRole(GUARDIAN_ROLE_, guardian);
  }

  function test_RenounceRole_RevertsForAdminRole() public {
    vm.prank(admin);
    vm.expectRevert(IGuardianAccessControl.RenounceRoleDisabled.selector);
    control.renounceRole(ADMIN_ROLE_, admin);
  }

  // ========== revokeRole (last-guardian invariant) ==========

  function test_RevokeRole_RevertsWhenLastGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(IGuardianAccessControl.LastGuardian.selector);
    control.revokeRole(GUARDIAN_ROLE_, guardian);
  }

  function test_RevokeRole_GuardianCanRevokeOtherGuardianWhenTwoExist() public {
    address secondGuardian = makeAddr("secondGuardian");

    vm.prank(guardian);
    control.grantRole(GUARDIAN_ROLE_, secondGuardian);

    vm.prank(secondGuardian);
    control.revokeRole(GUARDIAN_ROLE_, guardian);

    assertFalse(control.hasRole(GUARDIAN_ROLE_, guardian));
    assertTrue(control.hasRole(GUARDIAN_ROLE_, secondGuardian));

    // The remaining guardian is now protected again.
    vm.prank(secondGuardian);
    vm.expectRevert(IGuardianAccessControl.LastGuardian.selector);
    control.revokeRole(GUARDIAN_ROLE_, secondGuardian);
  }

  function test_RevokeRole_DoubleGrantDoesNotInflateGuardianCount() public {
    // Granting the same guardian twice is a no-op the second time and must not
    // double-count, otherwise the last-guardian invariant could be bypassed.
    vm.prank(guardian);
    control.grantRole(GUARDIAN_ROLE_, guardian);

    vm.prank(guardian);
    vm.expectRevert(IGuardianAccessControl.LastGuardian.selector);
    control.revokeRole(GUARDIAN_ROLE_, guardian);
  }

  function test_RevokeRole_NonGuardianRoleUnaffectedByInvariant() public {
    vm.prank(guardian);
    control.revokeRole(ADMIN_ROLE_, admin);

    assertFalse(control.hasRole(ADMIN_ROLE_, admin));
  }

  // ========== _isAdminOrGuardian ==========

  function test_IsAdminOrGuardian_TrueForGuardianAndAdmin_FalseForOthers() public view {
    assertTrue(control.exposed_isAdminOrGuardian(guardian));
    assertTrue(control.exposed_isAdminOrGuardian(admin));
    assertFalse(control.exposed_isAdminOrGuardian(randomUser));
    assertFalse(control.exposed_isAdminOrGuardian(address(0)));
  }
}
