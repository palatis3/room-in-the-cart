import assert from "node:assert/strict";
import test from "node:test";
import { publicConfiguration } from "../dist/config.js";

test("debug can remain disconnected without manufacturing a live service", () => {
  assert.deepEqual(publicConfiguration({ environment: "debug", apiOrigin: null }), { environment: "debug", apiOrigin: null });
});

test("public configuration excludes arbitrary private input", () => {
  const result = publicConfiguration({ environment: "staging", apiOrigin: "https://api.example.test", databasePassword: "fixture-secret", householdBudget: 3800 });
  assert.deepEqual(result, { environment: "staging", apiOrigin: "https://api.example.test" });
  assert.equal(Object.isFrozen(result), true);
});

test("deployed environments reject missing, credentialed, and non-HTTPS origins", () => {
  for (const apiOrigin of [null, "http://api.example.test", "https://user:secret@api.example.test", "https://api.example.test/private", "https://api.example.test/?token=secret"]) {
    assert.throws(() => publicConfiguration({ environment: "production", apiOrigin }));
  }
  assert.throws(() => publicConfiguration({ environment: "prod", apiOrigin: "https://api.example.test" }));
});
