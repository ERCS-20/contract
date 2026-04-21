import assert from "node:assert/strict";

export async function expectRevert(
  fn: () => Promise<unknown>,
  hint?: string,
): Promise<void> {
  try {
    await fn();
  } catch (e: unknown) {
    if (hint !== undefined) {
      const msg = e instanceof Error ? `${e.message}${"cause" in e && e.cause instanceof Error ? ` ${e.cause.message}` : ""}` : String(e);
      assert.ok(
        msg.includes(hint),
        `expected revert hint "${hint}" in message, got: ${msg}`,
      );
    }
    return;
  }
  assert.fail("expected transaction to revert");
}
