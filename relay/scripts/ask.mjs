// Signs in to a relay with a pairing code and calls one tool, printing
// {tools, result} as JSON. Used by the app's live test:
//   node ask.mjs <relay> <pairing code> <tool> [arguments JSON]
import { rpc, signIn } from "./client.mjs";

const [base, code, tool, args = "{}"] = process.argv.slice(2);
const token = await signIn(base, code, { name: "Live test" });
const tools = (await rpc(base, token, "tools/list")).body.result.tools.map((t) => t.name);
const result = (await rpc(base, token, "tools/call", { name: tool, arguments: JSON.parse(args) })).body.result;
console.log(JSON.stringify({ tools, result }));
