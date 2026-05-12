import { describe, expect, it } from "vitest";
import {
  applySubstitutions,
  escapeForLocation,
  extractPlaceholders,
} from "../src/placeholder.js";

describe("applySubstitutions", () => {
  it("substitutes a single placeholder in a URL", () => {
    expect(
      applySubstitutions("/coins/<<id>>/history", { id: "bitcoin" }, "url"),
    ).toBe("/coins/bitcoin/history");
  });

  it("percent-encodes URL values", () => {
    expect(
      applySubstitutions("/q=<<term>>", { term: "hello world&foo=bar" }, "url"),
    ).toBe("/q=hello%20world%26foo%3Dbar");
  });

  it("JSON-escapes body values (quote / backslash / newline)", () => {
    const out = applySubstitutions(
      '{"text":"<<msg>>"}',
      { msg: 'he said "hi"\nback\\slash' },
      "body",
    );
    expect(out).toBe('{"text":"he said \\"hi\\"\\nback\\\\slash"}');
    // Sanity: result is still parseable JSON
    expect(JSON.parse(out)).toEqual({ text: 'he said "hi"\nback\\slash' });
  });

  it("passes header values through unmodified", () => {
    expect(
      applySubstitutions("Bearer <<token>>", { token: "abc/123+xyz=" }, "header"),
    ).toBe("Bearer abc/123+xyz=");
  });

  it("substitutes multiple placeholders in source order", () => {
    expect(
      applySubstitutions("/a/<<x>>/b/<<y>>/c/<<x>>", { x: "X", y: "Y" }, "url"),
    ).toBe("/a/X/b/Y/c/X");
  });

  it("throws when a placeholder has no substitution value", () => {
    expect(() =>
      applySubstitutions("/coins/<<id>>/x", {}, "url"),
    ).toThrow(/<<id>>/);
  });

  it("leaves a template with no placeholders unchanged", () => {
    expect(applySubstitutions("plain text", {}, "url")).toBe("plain text");
  });
});

describe("escapeForLocation", () => {
  it("percent-encodes for url", () => {
    expect(escapeForLocation("a b", "url")).toBe("a%20b");
  });
  it("strips JSON quoting wrappers for body", () => {
    expect(escapeForLocation('he said "hi"', "body")).toBe('he said \\"hi\\"');
  });
});

describe("extractPlaceholders", () => {
  it("returns keys in order, preserving duplicates", () => {
    expect(extractPlaceholders("/<<a>>/<<b>>/<<a>>")).toEqual(["a", "b", "a"]);
  });
  it("returns an empty array on a plain template", () => {
    expect(extractPlaceholders("nothing here")).toEqual([]);
  });
});
