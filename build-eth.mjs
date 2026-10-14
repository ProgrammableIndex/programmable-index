#!/usr/bin/env node
// Programmable Index — native-ETH, launch-seeded Programmable custom launch builder (Ethereum profile 3.6, 4-target graph).
// Graph (CREATE2, all deployed + initialized in ONE Router transaction on ProgrammableLaunchStampRouter24hV1):
//   initializer  IndexSeededLaunchInitializerV1   seeds the token inventory as one locked single-sided v4 position,
//                                                 registers the pool (vault = project-fee owner), binds the vault and
//                                                 executes the first buy with msg.value
//   token        IndexRewardTokenV1               fixed supply + holder reward-point accounting (no owner/mint/tax)
//   hook         DecayingVolumeFeeHookV1          reference volume-fee kernel with a linearly decaying fee schedule
//   vault        IndexBasketVaultV1               project-fee owner: converts ETH fees into the fixed reward basket
// Derived from @programmable/launch examples/direct-native-v3-no-broadcast/project/build-and-configure.mjs.

import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdir, open, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const EXPECTED_SOLC = "0.8.26+commit.8a97fa7a.Emscripten.clang";
const GRAPH_FACTORY = "0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887";
const POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90";
const NATIVE_CURRENCY = "0x0000000000000000000000000000000000000000";
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const ENTRYPOINTS = Object.freeze([
  "src/IndexRewardTokenV1.sol",
  "src/IndexSeededLaunchInitializerV1.sol",
  "src/DecayingVolumeFeeHookV1.sol",
  "src/IndexBasketVaultV1.sol",
]);

if (process.argv.includes("--help")) {
  process.stdout.write(`native-ETH launch-seeded build

Required environment:
  PROGRAMMABLE_LAUNCH_WALLET       nonzero Ethereum address (signs the Router tx, receives team + first buy)
  PROGRAMMABLE_SOURCE_REVISION     exact lowercase 40-character public Git commit
  PROGRAMMABLE_LAUNCH_NONCE        nonzero lowercase bytes32
  PROGRAMMABLE_PROJECT_IMAGE_SOURCE_PATH relative local PNG/JPEG/WebP/GIF path
  PROGRAMMABLE_PROJECT_IMAGE_URI   matching canonical HTTPS, ipfs, or ar URI
  PROGRAMMABLE_WEBSITE_URL         canonical public HTTPS project website
  PROGRAMMABLE_X_URL               canonical https://x.com/<project_handle> profile
  PROGRAMMABLE_TICK_UPPER          opening tick (multiple of tick spacing); price = 1.0001^tick token-wei per wei
  PROGRAMMABLE_TICK_LOWER          lower bound of the seeded token range (multiple of tick spacing)

Optional public environment:
  PROGRAMMABLE_PUBLIC_ORIGIN, PROGRAMMABLE_CHECKED_AT, PROGRAMMABLE_SOURCE_LINEAGE_NONCE
  PROGRAMMABLE_POOL_FEE            integer 0..999999 (default 0)
  PROGRAMMABLE_TICK_SPACING        integer 1..32767 (default 60)
  PROGRAMMABLE_BUY_FEE_START / PROGRAMMABLE_BUY_FEE_FLOOR     total fee, hundredths of a bip 3000..50000 (0.30%..5%)
  PROGRAMMABLE_SELL_FEE_START / PROGRAMMABLE_SELL_FEE_FLOOR   total fee, hundredths of a bip 3000..50000 (0.30%..5%)
  PROGRAMMABLE_FEE_DECAY_SECONDS   linear decay window in seconds (default 300)
  PROGRAMMABLE_VAULT_KEEPER        harvest keeper of the basket vault (default launch wallet)
  PROGRAMMABLE_VAULT_DEV_WALLET    receives the vault dev share in ETH (default launch wallet)
  PROGRAMMABLE_VAULT_DEV_SHARE_BPS dev share of the project fee, bps 0..5000 (default 0)
  PROGRAMMABLE_VAULT_MIN_HARVEST_WEI   minimum ETH per harvest (default 0)
  PROGRAMMABLE_VAULT_PUBLIC_DELAY  seconds without harvest before anyone may run the WETH-only public harvest (default 259200)
  PROGRAMMABLE_VAULT_ROUTES_JSON   JSON array of reward routes (asset, kind, weightBps, v3Pool, v4Fee, v4TickSpacing, v4Hooks)
  PROGRAMMABLE_INITIAL_BUY_WEI     exact Router msg.value spent as the first buy (default 0 = no buy)
  PROGRAMMABLE_INITIAL_BUY_MIN_TOKENS  minimum token base units the first buy must return
  PROGRAMMABLE_TOKEN_NAME / PROGRAMMABLE_TOKEN_SYMBOL / PROGRAMMABLE_TOKEN_SUPPLY / PROGRAMMABLE_INVENTORY_SUPPLY
  PROGRAMMABLE_PROJECT_DESCRIPTION, PROGRAMMABLE_DISCORD_URL, PROGRAMMABLE_TELEGRAM_URL
  PROGRAMMABLE_PERMIT_WINDOW_SECONDS  Router permit validity (default 84600, max 86400 on the 24h Router)
`);
  process.exit(0);
}
if (process.argv.length !== 2) {
  throw new TypeError("build accepts only --help; configure public inputs through the documented environment");
}

const root = process.cwd();
const launchWallet = address(required("PROGRAMMABLE_LAUNCH_WALLET"), { label: "PROGRAMMABLE_LAUNCH_WALLET", nonzero: true });
const revision = required("PROGRAMMABLE_SOURCE_REVISION");
if (!/^[0-9a-f]{40}$/.test(revision)) {
  throw new TypeError("PROGRAMMABLE_SOURCE_REVISION must be an exact lowercase 40-character Git commit");
}
const nonce = required("PROGRAMMABLE_LAUNCH_NONCE");
if (!/^0x(?!0{64}$)[0-9a-f]{64}$/.test(nonce)) {
  throw new TypeError("PROGRAMMABLE_LAUNCH_NONCE must be a nonzero lowercase bytes32");
}
const publicOrigin = required("PROGRAMMABLE_PUBLIC_ORIGIN");
const publicOriginUrl = new URL(publicOrigin);
if (publicOriginUrl.protocol !== "https:" || publicOriginUrl.username || publicOriginUrl.password || publicOriginUrl.hash) {
  throw new TypeError("PROGRAMMABLE_PUBLIC_ORIGIN must be credential-free HTTPS without a fragment");
}
const checkedAt = process.env.PROGRAMMABLE_CHECKED_AT ?? new Date().toISOString();
if (new Date(checkedAt).toISOString() !== checkedAt) {
  throw new TypeError("PROGRAMMABLE_CHECKED_AT must be canonical UTC with milliseconds");
}
const sourceLineageNonce = canonicalUint(process.env.PROGRAMMABLE_SOURCE_LINEAGE_NONCE ?? "1", "PROGRAMMABLE_SOURCE_LINEAGE_NONCE");
const quoteCurrency = NATIVE_CURRENCY;
const poolFee = boundedInteger("PROGRAMMABLE_POOL_FEE", 0, 0, 999_999);
const tickSpacing = boundedInteger("PROGRAMMABLE_TICK_SPACING", 60, 1, 32_767);
const tickLower = signedBoundedInteger("PROGRAMMABLE_TICK_LOWER", -887_272, 887_272);
const tickUpper = signedBoundedInteger("PROGRAMMABLE_TICK_UPPER", -887_272, 887_272);
if (tickLower >= tickUpper || tickLower % tickSpacing !== 0 || tickUpper % tickSpacing !== 0) {
  throw new TypeError("PROGRAMMABLE_TICK_LOWER < PROGRAMMABLE_TICK_UPPER and both must be multiples of the tick spacing");
}
// Review cap: total hook fee (0.30% platform + project) must stay <= 5% at every point of the schedule.
const MAX_TOTAL_FEE = 50_000;        // long-run floor cap (5%), enforced by the hook
const MAX_LAUNCH_FEE = 250_000;      // opening cap (25%), only with a decay window <= 300 s
const MAX_LAUNCH_DECAY = 300;
const buyFeeStart = boundedInteger("PROGRAMMABLE_BUY_FEE_START", 50_000, 3000, MAX_LAUNCH_FEE);
const buyFeeFloor = boundedInteger("PROGRAMMABLE_BUY_FEE_FLOOR", 30_000, 3000, MAX_TOTAL_FEE);
const sellFeeStart = boundedInteger("PROGRAMMABLE_SELL_FEE_START", 50_000, 3000, MAX_LAUNCH_FEE);
const sellFeeFloor = boundedInteger("PROGRAMMABLE_SELL_FEE_FLOOR", 30_000, 3000, MAX_TOTAL_FEE);
const feeDecaySeconds = boundedInteger("PROGRAMMABLE_FEE_DECAY_SECONDS", 300, 0, 4_294_967_295);
if ((buyFeeStart > MAX_TOTAL_FEE || sellFeeStart > MAX_TOTAL_FEE) && feeDecaySeconds > MAX_LAUNCH_DECAY) {
  throw new RangeError(`an opening fee above 5% must decay to its floor within ${MAX_LAUNCH_DECAY} seconds`);
}
for (const [start, floor] of [[buyFeeStart, buyFeeFloor], [sellFeeStart, sellFeeFloor]]) {
  if (floor > start || (feeDecaySeconds === 0 && floor !== start)) {
    throw new TypeError("fee floor must be <= fee start, and equal to it when the decay window is 0");
  }
}
const buyFeeSchedule = [buyFeeStart, buyFeeFloor, feeDecaySeconds];
const sellFeeSchedule = [sellFeeStart, sellFeeFloor, feeDecaySeconds];
const vaultKeeper = address(process.env.PROGRAMMABLE_VAULT_KEEPER ?? launchWallet, { label: "PROGRAMMABLE_VAULT_KEEPER", nonzero: true });
const vaultDevWallet = address(process.env.PROGRAMMABLE_VAULT_DEV_WALLET ?? launchWallet, { label: "PROGRAMMABLE_VAULT_DEV_WALLET", nonzero: true });
const vaultDevShareBps = boundedInteger("PROGRAMMABLE_VAULT_DEV_SHARE_BPS", 0, 0, 5000);
const vaultMinHarvestWei = canonicalUint(process.env.PROGRAMMABLE_VAULT_MIN_HARVEST_WEI ?? "0", "PROGRAMMABLE_VAULT_MIN_HARVEST_WEI");
const vaultPublicDelay = boundedInteger("PROGRAMMABLE_VAULT_PUBLIC_DELAY", 259_200, 3_600, 31_536_000);
const vaultRoutes = parseRoutes(required("PROGRAMMABLE_VAULT_ROUTES_JSON"));
const initialBuyWei = canonicalUint(process.env.PROGRAMMABLE_INITIAL_BUY_WEI ?? "0", "PROGRAMMABLE_INITIAL_BUY_WEI");
const initialBuyMinTokens = canonicalUint(process.env.PROGRAMMABLE_INITIAL_BUY_MIN_TOKENS ?? (initialBuyWei === "0" ? "0" : "1"), "PROGRAMMABLE_INITIAL_BUY_MIN_TOKENS");
if (initialBuyWei !== "0" && initialBuyMinTokens === "0") {
  throw new TypeError("PROGRAMMABLE_INITIAL_BUY_MIN_TOKENS must be nonzero when a first buy is funded");
}
const tokenSupply = canonicalUint(process.env.PROGRAMMABLE_TOKEN_SUPPLY ?? "1000000000000000000000000000", "PROGRAMMABLE_TOKEN_SUPPLY", { nonzero: true });
const inventorySupply = canonicalUint(process.env.PROGRAMMABLE_INVENTORY_SUPPLY ?? tokenSupply, "PROGRAMMABLE_INVENTORY_SUPPLY", { nonzero: true });
if (BigInt(inventorySupply) > BigInt(tokenSupply)) throw new TypeError("PROGRAMMABLE_INVENTORY_SUPPLY must not exceed PROGRAMMABLE_TOKEN_SUPPLY");
const launchLimitSeconds = boundedInteger("PROGRAMMABLE_LAUNCH_LIMIT_SECONDS", 0, 0, 3600);
const launchMaxBuy = canonicalUint(process.env.PROGRAMMABLE_LAUNCH_MAX_BUY ?? "0", "PROGRAMMABLE_LAUNCH_MAX_BUY");
if (launchLimitSeconds !== 0 && (launchMaxBuy === "0" || BigInt(launchMaxBuy) > BigInt(tokenSupply))) {
  throw new RangeError("PROGRAMMABLE_LAUNCH_MAX_BUY must be in 1..supply when PROGRAMMABLE_LAUNCH_LIMIT_SECONDS > 0");
}
if (launchLimitSeconds !== 0 && initialBuyMinTokens !== "0" && BigInt(initialBuyMinTokens) > BigInt(launchMaxBuy)) {
  throw new RangeError("the dev buy minimum exceeds the launch buy limit — lower PROGRAMMABLE_INITIAL_BUY_WEI");
}
const tokenName = publicText(process.env.PROGRAMMABLE_TOKEN_NAME ?? "Native Launch Token", "PROGRAMMABLE_TOKEN_NAME", 64);
const tokenSymbol = publicText(process.env.PROGRAMMABLE_TOKEN_SYMBOL ?? "NLT", "PROGRAMMABLE_TOKEN_SYMBOL", 16, { whitespace: false });
const projectDescription = publicText(
  process.env.PROGRAMMABLE_PROJECT_DESCRIPTION ?? "Native ETH launch with locked seeded liquidity and a decaying fee",
  "PROGRAMMABLE_PROJECT_DESCRIPTION",
  4096,
  { multiline: true },
);
if ([...projectDescription].length < 20 || [...projectDescription.matchAll(/[\p{L}\p{N}]/gu)].length < 8) {
  throw new TypeError("PROGRAMMABLE_PROJECT_DESCRIPTION must contain at least 20 characters and 8 letters or numbers");
}
const projectImage = {
  sourcePath: publicText(required("PROGRAMMABLE_PROJECT_IMAGE_SOURCE_PATH"), "PROGRAMMABLE_PROJECT_IMAGE_SOURCE_PATH", 2048),
  uri: publicText(required("PROGRAMMABLE_PROJECT_IMAGE_URI"), "PROGRAMMABLE_PROJECT_IMAGE_URI", 2048),
};
const projectLinks = [
  ["website", required("PROGRAMMABLE_WEBSITE_URL")],
  ["x", required("PROGRAMMABLE_X_URL")],
  ["discord", process.env.PROGRAMMABLE_DISCORD_URL],
  ["telegram", process.env.PROGRAMMABLE_TELEGRAM_URL],
].filter(([, uri]) => uri !== undefined).map(([kind, uri]) => ({
  kind,
  uri: publicText(uri, `PROGRAMMABLE_${kind.toUpperCase()}_URL`, 2048),
}));
const permitWindow = permitWindowFromEnv();

const solcScript = path.join(root, "node_modules", "solc", "solc.js");
// Windows cannot spawn the extension-less .bin shim; run the locked solc entry through this node binary instead
const solcExecutable = process.platform === "win32" ? process.execPath : path.join(root, "node_modules", ".bin", "solcjs");
const solcPrefixArgs = process.platform === "win32" ? [solcScript] : [];
const compilerVersion = (await runSolc(["--version"])).stdout.trim();
if (compilerVersion !== EXPECTED_SOLC) {
  throw new TypeError(`expected exact locked solc ${EXPECTED_SOLC}, received ${compilerVersion}`);
}
const dependencyLockBytes = await readFile(path.join(root, "package-lock.json"));

const sources = await collectSoliditySources(ENTRYPOINTS);
const standardJson = {
  language: "Solidity",
  sources: Object.fromEntries([...sources.entries()]
    .sort(([left], [right]) => Buffer.compare(Buffer.from(left), Buffer.from(right)))
    .map(([sourceName, content]) => [sourceName, { content }])),
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "cancun",
    viaIR: true,
    metadata: { bytecodeHash: "none", appendCBOR: false, useLiteralContent: true },
    libraries: {},
    remappings: [],
    outputSelection: {
      "*": {
        "*": [
          "abi",
          "metadata",
          "evm.bytecode.object",
          "evm.bytecode.linkReferences",
          "evm.deployedBytecode.object",
          "evm.deployedBytecode.linkReferences",
          "evm.deployedBytecode.immutableReferences",
        ],
        "": ["ast"],
      },
    },
  },
};
const standardJsonBytes = Buffer.from(`${JSON.stringify(standardJson)}\n`, "utf8");
const standardJsonPath = path.join(root, "standard-json/native-eth-launch.json");
const compilerOutputPath = path.join(root, "standard-json/.native-eth-launch-output.json");
await mkdir(path.dirname(standardJsonPath), { recursive: true });
await writeFile(standardJsonPath, standardJsonBytes);
await runSolc(["--standard-json"], standardJsonPath, compilerOutputPath);
const compilerOutputText = await readFile(compilerOutputPath, "utf8");
const jsonStart = compilerOutputText.indexOf("{");
if (jsonStart === -1) throw new TypeError("locked solc returned no Standard JSON output");
const output = JSON.parse(compilerOutputText.slice(jsonStart));
const compilationErrors = (output.errors ?? []).filter(({ severity }) => severity === "error");
if (compilationErrors.length !== 0) {
  throw new TypeError(`solc failed:\n${compilationErrors.map(({ formattedMessage }) => formattedMessage).join("\n")}`);
}

const selectedArtifacts = [
  artifact(output, "src/IndexSeededLaunchInitializerV1.sol", "IndexSeededLaunchInitializerV1", "initializer"),
  artifact(output, "src/IndexRewardTokenV1.sol", "IndexRewardTokenV1", "token"),
  artifact(output, "src/DecayingVolumeFeeHookV1.sol", "DecayingVolumeFeeHookV1", "hook"),
  artifact(output, "src/IndexBasketVaultV1.sol", "IndexBasketVaultV1", "vault"),
];
const artifactBytes = new Map(selectedArtifacts.map(({ targetId, value }) => [targetId, Buffer.from(`${JSON.stringify(value)}\n`, "utf8")]));
await mkdir(path.join(root, "artifacts"), { recursive: true });
await mkdir(path.join(root, "evidence"), { recursive: true });
for (const [targetId, bytes] of artifactBytes) {
  await writeFile(path.join(root, `artifacts/${targetId}.json`), bytes);
}

const initializerRuntimeImmutables = runtimeImmutablesForInitializer(output, selectedArtifacts[0].compiled);
const hookRuntimeImmutables = runtimeImmutablesForHook(output, selectedArtifacts[2].compiled);
const tokenRuntimeImmutables = runtimeImmutablesMapped(output, selectedArtifacts[1].compiled, "token", {
  poolManager: { abiType: "address", literal: POOL_MANAGER },
  initializer: { abiType: "address", target: "initializer" },
  rewardVault: { abiType: "address", target: "vault" },
});
const vaultRuntimeImmutables = runtimeImmutablesMapped(output, selectedArtifacts[3].compiled, "vault", {
  poolManager: { abiType: "address", literal: POOL_MANAGER },
  weth: { abiType: "address", literal: WETH },
  binder: { abiType: "address", target: "initializer" },
  devWallet: { abiType: "address", literal: vaultDevWallet },
  devShareBps: { abiType: "uint16", literal: String(vaultDevShareBps) },
  minHarvestWei: { abiType: "uint256", literal: vaultMinHarvestWei },
  publicHarvestDelay: { abiType: "uint256", literal: String(vaultPublicDelay) },
});

const evidence = {
  schemaVersion: "programmable.native-eth-launch-seeded-evidence.v1",
  profile: { profileId: "programmable.direct-native-hook-graph.v1", profileVersion: "3.6.0", profileRevision: 3, productionLaunchAuthorized: true },
  scope: { compile: true, pack: false, validate: false, submit: false, routerTransaction: false, walletBroadcast: false, stopAt: "pre-pack" },
  compilerVersion,
  compilerSettings: { evmVersion: "cancun", optimizerEnabled: true, optimizerRuns: 200, viaIR: true, metadataBytecodeHash: "none", appendCBOR: false },
  checkedAt,
  sourceRevision: revision,
  dependencyLockSha256: sha256(dependencyLockBytes),
  standardJsonSha256: sha256(standardJsonBytes),
  artifacts: Object.fromEntries([...artifactBytes].map(([targetId, bytes]) => [targetId, sha256(bytes)])),
  targetCount: 4,
  declaredHookPermissionMask: "0x20cc",
  pool: { quoteCurrency, fee: poolFee, tickSpacing, tickLower, tickUpper },
  feeSchedules: { buy: buyFeeSchedule, sell: sellFeeSchedule },
  initialBuyWei,
  vault: { keeper: vaultKeeper, devWallet: vaultDevWallet, devShareBps: vaultDevShareBps, minHarvestWei: vaultMinHarvestWei, publicHarvestDelay: vaultPublicDelay, routes: vaultRoutes },
};
await writeFile(path.join(root, "evidence/rehearsal.json"), Buffer.from(`${JSON.stringify(evidence, null, 2)}\n`, "utf8"), { mode: 0o600 });

const config = {
  schemaVersion: "programmable.launch-pack-config.v3",
  launchWallet,
  chainId: "1",
  nonce,
  source: {
    root: ".",
    paths: ["package-lock.json", "src"],
    sourceLineageNonce,
    publicOrigin: { url: publicOriginUrl.toString(), revision },
  },
  compilationUnits: [
    { compilationUnitId: "native-eth-launch-solc", standardJson: "standard-json/native-eth-launch.json" },
  ],
  targets: [
    {
      targetId: "initializer",
      compilationUnitId: "native-eth-launch-solc",
      artifact: "artifacts/initializer.json",
      applicantSalt: `0x${"01".repeat(32)}`,
      constructorArguments: [POOL_MANAGER, GRAPH_FACTORY, poolFee, tickSpacing, tickLower, tickUpper],
      initializer: {
        function: "initialize",
        arguments: [
          { target: "token" },
          { target: "hook" },
          { target: "vault" },
          launchWallet,
          initialBuyMinTokens,
          buyFeeSchedule,
          sellFeeSchedule,
        ],
      },
      deploymentValueWei: "0",
      initializerValueWei: initialBuyWei,
      componentKind: "other",
      declaredHookPermissions: null,
      runtimeImmutables: initializerRuntimeImmutables,
    },
    {
      targetId: "token",
      compilationUnitId: "native-eth-launch-solc",
      artifact: "artifacts/token.json",
      applicantSalt: `0x${"02".repeat(32)}`,
      constructorArguments: [tokenName, tokenSymbol, tokenSupply, { target: "initializer" }, inventorySupply, launchWallet, POOL_MANAGER, { target: "vault" }, launchMaxBuy, String(launchLimitSeconds)],
      initializer: null,
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "token",
      declaredHookPermissions: null,
      runtimeImmutables: tokenRuntimeImmutables,
    },
    {
      targetId: "hook",
      compilationUnitId: "native-eth-launch-solc",
      artifact: "artifacts/hook.json",
      applicantSalt: { mode: "deterministic-hook-permission-grind-v1", start: "0", maxAttempts: "262144" },
      constructorArguments: [POOL_MANAGER, { target: "initializer" }, quoteCurrency],
      initializer: null,
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "hook",
      declaredHookPermissions: ["beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"],
      runtimeImmutables: hookRuntimeImmutables,
    },
    {
      targetId: "vault",
      compilationUnitId: "native-eth-launch-solc",
      artifact: "artifacts/vault.json",
      applicantSalt: `0x${"04".repeat(32)}`,
      constructorArguments: [POOL_MANAGER, WETH, { target: "initializer" }, vaultKeeper, vaultDevWallet, String(vaultDevShareBps), vaultMinHarvestWei, String(vaultPublicDelay), vaultRoutes],
      initializer: null,
      deploymentValueWei: "0",
      initializerValueWei: "0",
      componentKind: "other",
      declaredHookPermissions: null,
      runtimeImmutables: vaultRuntimeImmutables,
    },
  ],
  pool: { tokenTargetId: "token", hookTargetId: "hook", fee: poolFee, tickSpacing, quoteCurrency },
  projectMetadata: {
    schemaVersion: "programmable.project-metadata-input.v1",
    token: { name: tokenName, symbol: tokenSymbol },
    presentation: { description: projectDescription, image: projectImage, links: projectLinks },
  },
  launchProfile: {
    schemaVersion: "programmable.direct-native-hook-graph-profile-selection.v3",
    profileId: "programmable.direct-native-hook-graph.v1",
    profileRevision: 3,
    targetRoles: {
      tokenTargetId: "token",
      hookTargetId: "hook",
      initializerTargetId: "initializer",
      platformFeeBindingTargetId: "hook",
    },
    liquidityModel: {
      schemaVersion: "programmable.direct-native-liquidity-model-intent.v1",
      model: "launch-seeded-concentrated-liquidity",
      declaredLaunchState: "assessment_required",
      liquidityTargetId: "initializer",
      assessment: {
        schemaVersion: "programmable.direct-native-liquidity-model-assessment.v1",
        status: "required",
        requestClaimsExecution: false,
        requiredVectorIds: [
          "liquidity.seeded.pool-active-liquidity",
          "liquidity.seeded.position-custody-and-withdrawal",
          "liquidity.seeded.buy-and-sell",
        ],
      },
    },
    fundingMode: initialBuyWei === "0" ? "none" : "wallet-transaction-value",
    accountingMode: "inclusive-selected-total",
    assessmentBase: "executed-gross-declared-quote",
    feeCurrency: "declared-quote-currency",
    claimMode: "claim-authority-selected-recipient",
    applicantSelectedBuyHundredthsOfBip: String(buyFeeFloor),
    applicantSelectedSellHundredthsOfBip: String(sellFeeFloor),
  },
  permitWindow,
  agentAttestation: {
    agentId: "programmable-index-basket-vault-v1",
    checkedAt,
    checks: [{ checkId: "exact-build-rehearsal", evidence: "evidence/rehearsal.json" }],
  },
};
await writeFile(path.join(root, "programmable-launch.config.json"), `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });

process.stdout.write(`${JSON.stringify({
  schemaVersion: "native-eth-launch-config-result.v1",
  profileId: config.launchProfile.profileId,
  configPath: path.join(root, "programmable-launch.config.json"),
  standardJsonPath,
  compilerVersion,
  sourceCount: Object.keys(standardJson.sources).length,
  targetCount: config.targets.length,
  hookRuntimeImmutableCount: hookRuntimeImmutables.length,
  initializerRuntimeImmutableCount: initializerRuntimeImmutables.length,
  pool: evidence.pool,
  feeSchedules: evidence.feeSchedules,
  initialBuyWei,
  next: "programmable-launch pack, then programmable-launch validate",
}, null, 2)}\n`);

function runtimeImmutablesForHook(compilerOutput, compiledHook) {
  const declarations = new Map();
  for (const source of Object.values(compilerOutput.sources ?? {})) walkAst(source.ast, declarations);
  const references = compiledHook.evm.deployedBytecode.immutableReferences ?? {};
  return Object.keys(references).sort((left, right) => BigInt(left) < BigInt(right) ? -1 : 1).map((immutableId) => {
    const declaration = declarations.get(immutableId);
    if (!declaration) throw new TypeError(`compiler immutable ${immutableId} has no AST declaration`);
    if (declaration.name === "poolManager") return { immutableId, abiType: "address", literal: POOL_MANAGER };
    if (declaration.name === "registrar") return { immutableId, abiType: "address", target: "initializer" };
    if (declaration.name === "quoteCurrencyAddress") return { immutableId, abiType: "address", literal: NATIVE_CURRENCY };
    throw new TypeError(`unmapped hook immutable ${immutableId} (${declaration.name}); do not guess runtime materialization`);
  });
}

function runtimeImmutablesMapped(compilerOutput, compiled, label, mapping) {
  const declarations = new Map();
  for (const source of Object.values(compilerOutput.sources ?? {})) walkAst(source.ast, declarations);
  const references = compiled.evm.deployedBytecode.immutableReferences ?? {};
  const seen = new Set();
  const out = Object.keys(references).sort((left, right) => BigInt(left) < BigInt(right) ? -1 : 1).map((immutableId) => {
    const declaration = declarations.get(immutableId);
    if (!declaration) throw new TypeError(`compiler immutable ${immutableId} has no AST declaration`);
    const mapped = mapping[declaration.name];
    if (!mapped) throw new TypeError(`unmapped ${label} immutable ${immutableId} (${declaration.name}); do not guess runtime materialization`);
    seen.add(declaration.name);
    return { immutableId, ...mapped };
  });
  for (const name of Object.keys(mapping)) if (!seen.has(name)) throw new TypeError(`${label} immutable ${name} expected but not in bytecode`);
  return out;
}

function parseRoutes(raw) {
  let routes;
  try { routes = JSON.parse(raw); } catch { throw new TypeError("PROGRAMMABLE_VAULT_ROUTES_JSON must be JSON"); }
  if (!Array.isArray(routes) || routes.length === 0 || routes.length > 8) throw new TypeError("1..8 reward routes required");
  let sum = 0;
  const out = routes.map((route, index) => {
    const kind = { WRAP_WETH: 0, UNISWAP_V3: 1, UNISWAP_V4_NATIVE: 2 }[route.kind];
    if (kind === undefined) throw new TypeError(`route ${index} kind must be WRAP_WETH, UNISWAP_V3 or UNISWAP_V4_NATIVE`);
    const weight = Number(route.weightBps);
    if (!Number.isInteger(weight) || weight <= 0 || weight > 10_000) throw new TypeError(`route ${index} weightBps invalid`);
    sum += weight;
    const zero = "0x0000000000000000000000000000000000000000";
    return {
      asset: address(route.asset, { label: `route ${index} asset`, nonzero: true }),
      kind: String(kind),
      weightBps: String(weight),
      v3Pool: address(route.v3Pool ?? zero, { label: `route ${index} v3Pool` }),
      v4Fee: String(route.v4Fee ?? 0),
      v4TickSpacing: String(route.v4TickSpacing ?? 0),
      v4Hooks: address(route.v4Hooks ?? zero, { label: `route ${index} v4Hooks` }),
    };
  });
  if (sum !== 10_000) throw new TypeError(`route weights must sum to 10000 bps, got ${sum}`);
  return out;
}

function runtimeImmutablesForInitializer(compilerOutput, compiledInitializer) {
  const declarations = new Map();
  for (const source of Object.values(compilerOutput.sources ?? {})) walkAst(source.ast, declarations);
  const references = compiledInitializer.evm.deployedBytecode.immutableReferences ?? {};
  const literals = {
    poolManager: { abiType: "address", literal: POOL_MANAGER },
    graphFactory: { abiType: "address", literal: GRAPH_FACTORY },
    lpFeePips: { abiType: "uint24", literal: String(poolFee) },
    tickSpacing: { abiType: "int24", literal: String(tickSpacing) },
    tickLower: { abiType: "int24", literal: String(tickLower) },
    tickUpper: { abiType: "int24", literal: String(tickUpper) },
  };
  return Object.keys(references).sort((left, right) => BigInt(left) < BigInt(right) ? -1 : 1).map((immutableId) => {
    const declaration = declarations.get(immutableId);
    if (!declaration) throw new TypeError(`compiler immutable ${immutableId} has no AST declaration`);
    const mapped = literals[declaration.name];
    if (!mapped) {
      throw new TypeError(`unmapped initializer immutable ${immutableId} (${declaration.name}); do not guess runtime materialization`);
    }
    return { immutableId, ...mapped };
  });
}

function permitWindowFromEnv() {
  const now = Math.floor(Date.now() / 1000);
  const seconds = boundedInteger("PROGRAMMABLE_PERMIT_WINDOW_SECONDS", 84_600, 600, 86_400);
  return { validAfter: String(now - 60), deadline: String(now + seconds) };
}

function signedBoundedInteger(name, minimum, maximum) {
  const raw = required(name);
  if (!/^-?(?:0|[1-9][0-9]*)$/.test(raw)) throw new TypeError(`${name} must be a canonical integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new TypeError(`${name} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

async function collectSoliditySources(entrypoints) {
  const collected = new Map();
  const pending = [...entrypoints];
  while (pending.length !== 0) {
    const sourceName = pending.shift();
    if (collected.has(sourceName)) continue;
    if (path.posix.isAbsolute(sourceName) || sourceName === ".." || sourceName.startsWith("../")) {
      throw new TypeError(`unsafe Solidity source name ${sourceName}`);
    }
    const content = await readSoliditySource(sourceName);
    collected.set(sourceName, content);
    for (const specifier of solidityImports(content)) {
      const imported = specifier.startsWith(".")
        ? path.posix.normalize(path.posix.join(path.posix.dirname(sourceName), specifier))
        : path.posix.normalize(specifier);
      if (imported === ".." || imported.startsWith("../") || path.posix.isAbsolute(imported)) {
        throw new TypeError(`unsafe Solidity import ${specifier} from ${sourceName}`);
      }
      if (!collected.has(imported) && !pending.includes(imported)) pending.push(imported);
    }
  }
  return collected;
}

async function readSoliditySource(sourceName) {
  const local = path.join(root, ...sourceName.split("/"));
  try {
    return await readFile(local, "utf8");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  const dependency = path.join(root, "node_modules", ...sourceName.split("/"));
  try {
    return await readFile(dependency, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new TypeError(`Solidity dependency ${sourceName} is absent; run npm ci first`);
    }
    throw error;
  }
}

function solidityImports(content) {
  const imports = [];
  const pattern = /^\s*import\s+(?:[^;]*?\sfrom\s+)?["']([^"']+)["']\s*;/gmu;
  for (let match = pattern.exec(content); match !== null; match = pattern.exec(content)) {
    imports.push(match[1]);
  }
  return imports;
}

function artifact(compilerOutput, sourceName, contractName, targetId) {
  const compiled = compilerOutput.contracts?.[sourceName]?.[contractName];
  if (!compiled?.abi || !compiled?.metadata || !compiled?.evm?.bytecode?.object
    || !compiled?.evm?.deployedBytecode?.object) {
    throw new TypeError(`compiler output is incomplete for ${sourceName}:${contractName}`);
  }
  return {
    targetId,
    compiled,
    value: {
      abi: compiled.abi,
      bytecode: compiled.evm.bytecode,
      deployedBytecode: compiled.evm.deployedBytecode,
      metadata: compiled.metadata,
    },
  };
}

function walkAst(node, declarations) {
  if (node === null || typeof node !== "object") return;
  if (node.nodeType === "VariableDeclaration" && node.mutability === "immutable"
    && Number.isSafeInteger(node.id) && typeof node.name === "string") {
    declarations.set(String(node.id), { name: node.name, type: node.typeDescriptions?.typeString ?? null });
  }
  for (const value of Object.values(node)) {
    if (Array.isArray(value)) {
      for (const child of value) walkAst(child, declarations);
    } else if (value !== null && typeof value === "object") {
      walkAst(value, declarations);
    }
  }
}

function canonicalUint(value, label, { nonzero = false } = {}) {
  if (typeof value !== "string" || !/^(?:0|[1-9][0-9]*)$/.test(value)
    || BigInt(value) >= 1n << 256n || (nonzero && value === "0")) {
    throw new TypeError(`${label} must be a canonical ${nonzero ? "nonzero " : ""}uint256`);
  }
  return value;
}

function boundedInteger(name, fallback, minimum, maximum) {
  const raw = process.env[name] ?? String(fallback);
  if (!/^(?:0|[1-9][0-9]*)$/.test(raw)) throw new TypeError(`${name} must be a canonical integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new TypeError(`${name} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

function address(value, { label, nonzero = false }) {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)
    || (nonzero && /^0x0{40}$/i.test(value))) {
    throw new TypeError(`${label} must be a ${nonzero ? "nonzero " : ""}Ethereum address`);
  }
  return value;
}

function publicText(value, label, maximumBytes, {
  empty = false,
  multiline = false,
  whitespace = true,
} = {}) {
  if (typeof value !== "string" || value !== value.normalize("NFC") || value.trim() !== value
    || (!empty && value.length === 0) || Buffer.byteLength(value, "utf8") > maximumBytes
    || (multiline
      ? /[\u0000-\u0009\u000b-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/u.test(value)
      : /[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/u.test(value))
    || (!whitespace && /\s/u.test(value))) {
    throw new TypeError(`${label} must be canonical public text within ${maximumBytes} UTF-8 bytes`);
  }
  return value;
}

function required(name) {
  const value = process.env[name];
  if (!value) throw new TypeError(`${name} is required`);
  return value;
}

function assertDigest(bytes, expected, label) {
  const actual = sha256(bytes);
  if (actual !== expected) throw new TypeError(`${label} differs: expected ${expected}, received ${actual}`);
}

function sha256(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

async function runSolc(args, inputPath = null, outputPath = null) {
  const inputHandle = inputPath === null ? null : await open(inputPath, "r");
  const outputHandle = outputPath === null ? null : await open(outputPath, "w", 0o600);
  return new Promise((resolve, reject) => {
    const child = spawn(solcExecutable, [...solcPrefixArgs, ...args], {
      cwd: root,
      env: {
        ...process.env,
        PATH: `${path.dirname(solcExecutable)}${path.delimiter}${process.env.PATH ?? ""}`,
      },
      stdio: [inputHandle?.fd ?? "ignore", outputHandle?.fd ?? "pipe", "pipe"],
    });
    void inputHandle?.close();
    void outputHandle?.close();
    let stdout = "";
    let stderr = "";
    child.stdout?.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      if (error?.code === "ENOENT") {
        reject(new TypeError("locked solcjs is absent; run npm ci before npm run build"));
      } else {
        reject(error);
      }
    });
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new TypeError(`locked solcjs exited ${String(code)}: ${stderr.trim()}`));
      } else {
        resolve({ stdout, stderr });
      }
    });
  });
}
