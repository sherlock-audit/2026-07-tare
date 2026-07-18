export enum Roles {
  Borrower = 0,
  Originator = 1,
  Investor = 2,
  Servicer = 3,
}

const ROLE_NAMES = Object.keys(Roles).filter((k) => isNaN(Number(k))) as (keyof typeof Roles)[]

export function parseRole(value: string): Roles {
  const match = ROLE_NAMES.find((r) => r.toLowerCase() === value.toLowerCase())
  if (!match) throw new Error(`Invalid role: ${value}. Valid roles: ${ROLE_NAMES.join(", ")}`)
  return Roles[match]
}

export function roleToUint(role: Roles): string {
  return String(role)
}

export const VALID_ROLE_NAMES = ROLE_NAMES
