import { test } from "node:test";
import assert from "node:assert/strict";
import { greet } from "../dist/index.js";

test("greet", () => {
  assert.equal(greet("world"), "Hello, world!");
});
