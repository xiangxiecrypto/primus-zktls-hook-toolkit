/**
 * Decode test/fixtures/real-submit.hex and print the actual Attestation
 * fields Primus returned, so we can diff against what the SDK expects.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { decodeAbiParameters, parseAbiParameters } from "viem";

const ATT =
  "(address recipient," +
  "(string url,string header,string method,string body) request," +
  "(string keyName,string parseType,string parsePath)[] reponseResolve," +
  "string data," +
  "string attConditions," +
  "uint64 timestamp," +
  "string additionParams," +
  "(address attestorAddr,string url)[] attestors," +
  "bytes[] signatures)";

const hex = readFileSync(resolve(import.meta.dirname, "../../test/fixtures/real-submit.hex"), "utf-8") as `0x${string}`;

const params = parseAbiParameters(`${ATT}[] atts, bytes custom`);
const [atts] = decodeAbiParameters(params, hex) as [readonly Record<string, unknown>[], string];

for (const [i, a] of atts.entries()) {
  console.log("=== attestation", i, "===");
  console.log("request.url   :", (a.request as Record<string, unknown>).url);
  console.log("request.method:", (a.request as Record<string, unknown>).method);
  console.log("request.body  :", JSON.stringify((a.request as Record<string, unknown>).body));
  console.log("request.header:", (a.request as Record<string, unknown>).header);
  console.log("reponseResolve:", JSON.stringify(a.reponseResolve, null, 2));
  console.log("additionParams:", a.additionParams);
  console.log("data          :", a.data);
  console.log("timestamp     :", a.timestamp);
}
