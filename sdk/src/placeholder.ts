import type { BindingLocation } from "./types.js";

/**
 * Substitute `<<keyName>>` placeholders in a template string. Escaping is
 * per-location:
 *
 *  - "url"    → percent-encode the value (RFC 3986 component encoding).
 *  - "header" → no escaping (raw).
 *  - "body"   → JSON-aware escaping: the value is run through
 *               `JSON.stringify` and the surrounding quotes are stripped, so
 *               quotes, backslashes, newlines, and control characters
 *               become valid inside a JSON string literal.
 *
 * Design doc §5.9(c): body substitution MUST use JSON-aware escaping or the
 * resulting body either becomes invalid JSON (LLM 400s) or matches the
 * anchor in an unintended position (hook accepts but semantically wrong).
 */
export function applySubstitutions(
  template: string,
  substitutions: Record<string, string>,
  location: BindingLocation,
): string {
  return template.replace(/<<([^>]+)>>/g, (_match, key: string) => {
    if (!(key in substitutions)) {
      throw new Error(`No substitution value provided for placeholder <<${key}>>`);
    }
    const raw = substitutions[key]!;
    return escapeForLocation(raw, location);
  });
}

export function escapeForLocation(value: string, location: BindingLocation): string {
  switch (location) {
    case "url":
      return encodeURIComponent(value);
    case "header":
      return value;
    case "body": {
      // JSON.stringify produces a fully escaped quoted string; strip the
      // outer quotes so we can embed inside an existing JSON string literal.
      const quoted = JSON.stringify(value);
      return quoted.slice(1, -1);
    }
  }
}

/**
 * Extract every `<<keyName>>` placeholder appearing in a template, in source
 * order with duplicates preserved. Used by the spec builder to validate that
 * every placeholder has a corresponding binding before going on-chain.
 */
export function extractPlaceholders(template: string): string[] {
  const out: string[] = [];
  const re = /<<([^>]+)>>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(template)) !== null) {
    out.push(m[1]!);
  }
  return out;
}
