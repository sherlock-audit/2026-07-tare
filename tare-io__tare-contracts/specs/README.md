# Specification Writing Guide

This guide describes how to write technical specifications for Tare LMS. Specs serve as the source of truth for implementation by both human developers and LLM coding assistants.

## File Organization

```
specs/
```

Use markdown files (`.md`). Name files descriptively using snake_case (e.g., `loan_data_model.md`, `onchain_transactions.md`).

## Spec Structure

### 1. Title and Overview

Start with a clear H1 title and a 2-3 sentence overview explaining what the component does and why it exists.

```markdown
# Component Name Specification

Brief description of purpose and context. Mention key architectural decisions upfront.
```

### 2. Core Concepts

Define domain-specific terminology and mental models before diving into details. Use subsections for each concept.

### 3. Data Structures

Show concrete types with code blocks. For Solidity:

```solidity
struct LoanData {
    int128 principal;
    int128 principalRepaid;
    LoanStatus status;
}
```

For TypeScript/Drizzle schemas:

```typescript
export const loans = pgTable("loans", {
  id: uuid("id").primaryKey(),
  status: loanStatusEnum("status").notNull(),
})
```

### 4. Functions/Actions

Document each function with:

- Function signature (code block)
- Purpose (one line)
- Parameters (bulleted list)
- Validation rules
- State changes
- Events emitted

Example:

````markdown
### pay

```solidity
function pay(uint64 loanId, int128 amount, ...) external
```
````

**Purpose**: Deposit borrower payment and create ledger entry

**Parameters**:

- `loanId`: Target loan
- `borrowerAddress`: Address to pull tokens from
- `amount`: Total payment amount

**Validation**:

- Loan must exist
- Borrower address must be registered

**State Changes**:

- Pulls tokens into contract
- Creates ledger entry: BorrowerPaymentClearing → Cash

```

### 5. State Diagrams

Use ASCII diagrams for state machines:

```

pending → submitted → confirming → confirmed
↓
failed / reverted

````

### 6. Example Usage

Include concrete examples showing typical flows:

```typescript
// 1. Create transaction
const txId = await service.createTransaction({...})

// 2. Monitor status
await temporalClient.workflow.start(monitorWorkflow, {...})
````

### 7. Implementation Checklist

End with actionable tasks:

```markdown
## Implementation Checklist

- [ ] Add database schema
- [ ] Implement service layer
- [ ] Write unit tests
```

## Writing Guidelines

### Be Explicit

- Specify exact field names, types, and constraints
- Include error conditions and edge cases
- Define enums with numeric values when order matters

### Be Implementable

- Provide enough detail that an LLM can generate working code
- Include code sketches for complex logic
- Reference related specs with relative links: `[see ledger.md](./ledger.md)`

### Be Concise

- Avoid explaining basic concepts (Solidity syntax, SQL joins)
- Use tables for permission matrices or option comparisons
- Omit obvious validation ("id must be valid")
- Specs should be less than 2000 lines. Ideally less than 1000 lines of text.

### Security Considerations

- Call out access control requirements explicitly
- Document which roles can perform which actions
- Note reentrancy, overflow, or other vulnerability concerns

## Cross-References

Link related specs:

```markdown
This is defined in [specs/smart-accounts.md](./smart-accounts.md)
```

Reference implementation files when they exist:

```markdown
See `src/services/transactions.ts` for implementation.
```

## Diagrams

Use SVG for complex diagrams (place alongside the spec):

```markdown
![Overview](./Authentication_Safe.svg)
```

Use ASCII art for simple flows embedded in the document.

## Versioning

Update specs when implementation diverges—specs should reflect intended behavior, not legacy quirks.
