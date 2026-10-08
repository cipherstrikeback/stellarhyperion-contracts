#!/usr/bin/env node
/**
 * Assemble a Stellar deployment record and refuse to write it if it does not hold together.
 *
 * The validation is the point. A deployment record is read later by the keeper, the indexer and the
 * frontend, and an address with a transposed character parses fine as a string, survives a cast
 * without complaint, and becomes a transfer to nobody. So the record is built here and handed to
 * the same `parseDeploymentSet` those three use, which checks every contract id against the real
 * strkey codec, checks every rail name against the real route list, and names the field it choked
 * on. A malformed record never reaches disk.
 *
 * Reads its inputs from the environment because its caller is a shell script and marshalling two
 * dozen values through argv would be worse. Writes nothing but the file it was asked for, and
 * nothing it writes came from a secret: only the deployer's public address appears.
 *
 * Usage: node write-record.mjs <path>
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const contractsRoot = resolve(here, "..", "..");

let protocol;
try {
  protocol = await import(resolve(contractsRoot, "packages/protocol/dist/index.js"));
} catch (cause) {
  throw new Error(
    "the protocol package is not built, so the record cannot be validated. Run:\n" +
      "  cd packages/protocol && npm install && npm run build\n" +
      `(${String(cause)})`,
  );
}
const { parseDeploymentSet, DEPLOYMENT_SCHEMA_VERSION, chain, isStellarChain } = protocol;

const out = process.argv[2];
if (out === undefined) throw new Error("usage: write-record.mjs <path>");

function need(name) {
  const value = process.env[name];
  if (value === undefined || value === "") throw new Error(`${name} is not set`);
  return value;
}

/** Hyperion's key for the network the CLI was pointed at. */
function chainKeyFor(network) {
  if (network === "testnet" || network === "futurenet") return "stellar-testnet";
  if (network === "mainnet" || network === "public") return "stellar";
  throw new Error(`no Hyperion chain key for the network "${network}"`);
}

const network = need("STELLAR_NETWORK");
const chainKey = chainKeyFor(network);
const entry = chain(chainKey);
if (!isStellarChain(entry)) throw new Error(`${chainKey} is not a Stellar chain`);

/**
 * The ledger the deployment landed in, asked of the network rather than guessed.
 *
 * Worth a round trip: it is the only value in the record that lets somebody line the deployment up
 * against the chain's own history, and a wrong one makes an indexer start from the wrong place.
 */
async function latestLedger() {
  const response = await fetch(entry.defaultRpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "getLatestLedger" }),
  });
  if (!response.ok) throw new Error(`the rpc at ${entry.defaultRpcUrl} answered ${String(response.status)}`);
  const body = await response.json();
  const sequence = body?.result?.sequence;
  if (typeof sequence !== "number") throw new Error("the rpc did not return a ledger sequence");
  return sequence;
}

/** The commit the wasm was built from. The only thing tying a contract id to a source tree. */
function commit() {
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { cwd: contractsRoot, encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

const asset = need("HYPERION_ASSET");
const [code, issuer] = asset.split(":");
if (code === undefined || issuer === undefined) {
  throw new Error(`HYPERION_ASSET should read CODE:ISSUER, got "${asset}"`);
}

const adapters = {};
if (process.env.HYPERION_CCTP) adapters.cctp = process.env.HYPERION_CCTP;
if (process.env.HYPERION_AXELAR) adapters["axelar-its"] = process.env.HYPERION_AXELAR;

const routes = Object.keys(adapters);

const wasmHashes = {};
if (process.env.ROUTER_HASH) wasmHashes.router = process.env.ROUTER_HASH;
if (process.env.CCTP_HASH && process.env.HYPERION_CCTP) wasmHashes["adapter-cctp"] = process.env.CCTP_HASH;
if (process.env.AXELAR_HASH && process.env.HYPERION_AXELAR) {
  wasmHashes["adapter-axelar"] = process.env.AXELAR_HASH;
}

const deployment = {
  family: "stellar",
  networkPassphrase: entry.networkPassphrase,
  router: need("HYPERION_ROUTER"),
  adapters,
  tokens: {
    [code]: {
      sacId: need("HYPERION_SAC"),
      code,
      issuer,
      // Stellar's native precision, and the source of the one digit mismatch with USDC on EVM.
      decimals: 7,
      flowLimit: need("HYPERION_TOKEN_FLOW_LIMIT"),
      routes,
    },
  },
  treasury: need("HYPERION_TREASURY"),
  admin: need("HYPERION_ADMIN"),
  guardian: need("HYPERION_GUARDIAN"),
  feeBps: Number(need("HYPERION_FEE_BPS")),
  // Ledgers on this side, seconds on the EVM side. The field name is the same and the unit is not,
  // which is worth remembering every single time.
  flowWindow: Number(need("HYPERION_FLOW_WINDOW_LEDGERS")),
  timelockDelay: Number(need("HYPERION_TIMELOCK_DELAY")),
  wasmHashes,
  deployedAt: {
    ledger:
      process.env.HYPERION_ROUTER_LEDGER || process.env.ROUTER_LEDGER || process.env.STELLAR_START_LEDGER
        ? Number(
            process.env.HYPERION_ROUTER_LEDGER ||
              process.env.ROUTER_LEDGER ||
              process.env.STELLAR_START_LEDGER,
          )
        : await latestLedger(),
    timestamp: new Date().toISOString(),
  },
  commit: commit(),

  // Phase two reads these, and a reviewer checks them against the chain. The validator ignores
  // fields it does not know about, which is what lets a record carry handover state as well as
  // addresses.
  deployer: need("HYPERION_DEPLOYER"),
  peerChain: need("HYPERION_PEER_CHAIN"),
  queuedActionIds: JSON.parse(process.env.QUEUE_IDS_JSON ?? "[]"),
  queuedActions: JSON.parse(process.env.QUEUE_WHAT_JSON ?? "[]"),
};

const record = {
  schemaVersion: DEPLOYMENT_SCHEMA_VERSION,
  generatedAt: new Date().toISOString(),
  networks: { [chainKey]: deployment },
};

// The whole reason this file exists rather than a heredoc in the shell script.
parseDeploymentSet(record);

mkdirSync(dirname(resolve(out)), { recursive: true });
writeFileSync(resolve(out), `${JSON.stringify(record, null, 2)}\n`);
process.stdout.write(`validated and written: ${out}\n`);
