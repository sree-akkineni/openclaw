#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const memoryRoot = path.join(__dirname, "memory");
const rawRoot = path.join(memoryRoot, "raw");
const carryoverApprovedRoot = path.join(memoryRoot, "carryover", "approved");
const vaultRoot = path.join(memoryRoot, "obsidian-vault");
const qmdIngestRoot = path.join(memoryRoot, "qmd", "ingest");
const lintDir = path.join(memoryRoot, "lint");
const manifestPath = path.join(memoryRoot, "global", "compile-manifest.json");

const usage = `Usage:
  node scripts/ops/clawops/stream-c/memory-pipeline.mjs seed-sample
  node scripts/ops/clawops/stream-c/memory-pipeline.mjs seed-carryover-sample
  node scripts/ops/clawops/stream-c/memory-pipeline.mjs compile
  node scripts/ops/clawops/stream-c/memory-pipeline.mjs lint
  node scripts/ops/clawops/stream-c/memory-pipeline.mjs query --tier <global-shared|group-shared|person-private> --context-key <key> [--limit <n>]
  node scripts/ops/clawops/stream-c/memory-pipeline.mjs demo
`;

const nowIso = () => new Date().toISOString();

const hash8 = (value) => crypto.createHash("sha1").update(value).digest("hex").slice(0, 8);
const hash12 = (value) => crypto.createHash("sha1").update(value).digest("hex").slice(0, 12);

const slugify = (value) =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);

const unique = (items) => [...new Set(items)];
const toJsonArray = (value) => (Array.isArray(value) ? value : []);

const addDays = (isoDate, days) => {
  const date = new Date(`${isoDate}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
};

const retentionDaysForTier = (tier) => {
  if (tier === "global-shared") {
    return 60;
  }
  if (tier === "person-private") {
    return 30;
  }
  return 14;
};

const tierForSurface = (surface) => {
  if (surface === "global") {
    return "global-shared";
  }
  if (surface === "dm") {
    return "person-private";
  }
  return "group-shared";
};

const scopeForTier = (tier) => {
  if (tier === "global-shared") {
    return "global";
  }
  if (tier === "person-private") {
    return "dm";
  }
  return "group";
};

const sectionForScope = (scope) => {
  if (scope === "global") {
    return "global";
  }
  if (scope === "dm") {
    return "dm";
  }
  return "groups";
};

const ensureDir = async (dirPath) => {
  await fs.mkdir(dirPath, { recursive: true });
};

const writeFile = async (filePath, content) => {
  await ensureDir(path.dirname(filePath));
  await fs.writeFile(filePath, content, "utf8");
};

const readIfExists = async (filePath) => {
  try {
    return await fs.readFile(filePath, "utf8");
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
};

const parseJsonl = async (filePath) => {
  const raw = await fs.readFile(filePath, "utf8");
  const lines = raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  return lines.map((line, index) => {
    try {
      return JSON.parse(line);
    } catch {
      throw new Error(`Invalid JSON line in ${filePath}:${String(index + 1)}`);
    }
  });
};

const parseArgs = (argv) => {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      parsed[key] = "true";
      continue;
    }
    parsed[key] = value;
    index += 1;
  }
  return parsed;
};

const toFrontmatter = (record) => {
  const lines = [
    "---",
    `memory_id: ${record.memory_id}`,
    `schema_version: ${record.schema_version}`,
    `tier: ${record.tier}`,
    `scope: ${record.scope}`,
    `context_key: ${record.context_key}`,
    "source:",
    `  raw_files: [${record.source.raw_files.map((filePath) => `"${filePath}"`).join(", ")}]`,
    `  event_ids: [${record.source.event_ids.map((eventId) => `"${eventId}"`).join(", ")}]`,
    `confidence: ${record.confidence.toFixed(2)}`,
    `ttl_days: ${record.ttl_days}`,
    `retention_until: ${record.retention_until}`,
    `sensitivity: [${record.sensitivity.map((label) => `"${label}"`).join(", ")}]`,
    `created_at: ${record.created_at}`,
    `updated_at: ${record.updated_at}`,
    "links:",
    `  timeline: [${record.links.timeline.map((link) => `"${link}"`).join(", ")}]`,
    `  concepts: [${record.links.concepts.map((link) => `"${link}"`).join(", ")}]`,
    "---",
  ];
  return `${lines.join("\n")}\n`;
};

const summarizeEvents = (events) => {
  const keyPoints = unique(events.map((event) => event.text?.trim()).filter(Boolean)).slice(0, 5);
  const decisions = unique(
    events
      .filter((event) => Array.isArray(event.labels) && event.labels.includes("decision"))
      .map((event) => event.text?.trim())
      .filter(Boolean),
  );
  const openQuestions = unique(
    events.map((event) => event.text?.trim()).filter((text) => Boolean(text) && text.includes("?")),
  ).slice(0, 5);
  const entities = unique(
    events
      .flatMap((event) => (Array.isArray(event.entities) ? event.entities : []))
      .map((entity) => entity.trim())
      .filter(Boolean),
  );

  return {
    keyPoints,
    decisions,
    openQuestions,
    entities,
  };
};

const averageConfidence = (events) => {
  const values = events
    .map((event) => {
      if (typeof event.confidence === "number") {
        return event.confidence;
      }
      return 0.7;
    })
    .filter((value) => Number.isFinite(value));

  if (values.length === 0) {
    return 0.7;
  }

  const total = values.reduce((sum, value) => sum + value, 0);
  return Math.min(0.99, Math.max(0.5, total / values.length));
};

const buildSummaryMarkdown = (record, summary) => {
  const keyPointsLines =
    summary.keyPoints.length > 0
      ? summary.keyPoints.map((line) => `- ${line}`).join("\n")
      : "- No high-confidence points in this window.";
  const decisionsLines =
    summary.decisions.length > 0
      ? summary.decisions.map((line) => `- ${line}`).join("\n")
      : "- No explicit decisions detected.";
  const questionsLines =
    summary.openQuestions.length > 0
      ? summary.openQuestions.map((line) => `- ${line}`).join("\n")
      : "- No unresolved questions detected.";
  const conceptLines =
    record.links.concepts.length > 0
      ? record.links.concepts
          .map((conceptPath) => `- [[${conceptPath}|${path.basename(conceptPath)}]]`)
          .join("\n")
      : "- None";

  return `${toFrontmatter(record)}# Memory Summary\n\n## Key Points\n${keyPointsLines}\n\n## Decisions\n${decisionsLines}\n\n## Open Questions\n${questionsLines}\n\n## Timeline\n- [[${record.links.timeline[0]}]]\n\n## Concepts\n${conceptLines}\n`;
};

const buildCarryoverMarkdown = (record, carryover) => {
  const title = carryover.payload?.title?.trim() || "Carryover Artifact";
  const bullets = toJsonArray(carryover.payload?.bullets)
    .map((line) => String(line).trim())
    .filter(Boolean);
  const bulletLines =
    bullets.length > 0 ? bullets.map((line) => `- ${line}`).join("\n") : "- No carryover bullets.";
  const sourceDomain = String(carryover.source?.domain ?? "unknown");
  const sourceKey = String(carryover.source?.context_key ?? "unknown");
  const artifactId = String(carryover.artifact_id ?? "unknown");
  const consentBasis = String(carryover.consent_basis ?? "unknown");

  return `${toFrontmatter(record)}# ${title}\n\n## Carryover Metadata\n- artifact_id: \`${artifactId}\`\n- source: \`${sourceDomain} | ${sourceKey}\`\n- consent_basis: \`${consentBasis}\`\n\n## Carryover Points\n${bulletLines}\n\n## Timeline\n- [[${record.links.timeline[0]}]]\n`;
};

const createSummaryRecord = (events, rawFile) => {
  const first = events[0];
  if (!first) {
    return null;
  }

  const surface = first.surface ?? "group";
  const tier = tierForSurface(surface);
  const scope = scopeForTier(tier);
  const contextKey = first.context_key ?? `unknown:${hash8(rawFile)}`;
  const date = String(first.timestamp ?? nowIso()).slice(0, 10);
  const memoryId = `mem-${hash12(`${tier}|${contextKey}|${date}`)}`;
  const contextSlug = `${slugify(contextKey)}-${hash8(contextKey)}`;
  const noteRelativePath = path.posix.join(
    sectionForScope(scope),
    contextSlug,
    `${date}--summary.md`,
  );

  const summary = summarizeEvents(events);
  const confidence = averageConfidence(events);
  const ttlDays = retentionDaysForTier(tier);

  const conceptLinks = summary.entities.map(
    (entity) => `entities/${slugify(entity)}-${hash8(entity)}`,
  );
  const timelinePath = `timeline/${date}`;

  const noteRecord = {
    memory_id: memoryId,
    schema_version: "stream-c-v1",
    tier,
    scope,
    context_key: contextKey,
    source: {
      raw_files: [path.relative(memoryRoot, rawFile).replaceAll(path.sep, "/")],
      event_ids: unique(events.map((event) => event.event_id).filter(Boolean)).slice(0, 100),
    },
    confidence,
    ttl_days: ttlDays,
    retention_until: addDays(date, ttlDays),
    sensitivity: unique(
      events
        .flatMap((event) => (Array.isArray(event.sensitivity) ? event.sensitivity : ["internal"]))
        .filter(Boolean),
    ),
    created_at: nowIso(),
    updated_at: nowIso(),
    links: {
      timeline: [timelinePath],
      concepts: conceptLinks,
    },
  };

  return {
    memoryId,
    tier,
    scope,
    contextKey,
    contextSlug,
    date,
    noteRelativePath,
    noteRecord,
    summary,
    text: unique([...summary.keyPoints, ...summary.decisions, ...summary.openQuestions])
      .join(" ")
      .trim(),
  };
};

const parseCarryoverFile = async (filePath) => {
  const raw = await fs.readFile(filePath, "utf8");
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error(`Invalid JSON in carryover file: ${filePath}`);
  }
};

const validateApprovedCarryover = (carryover, filePath) => {
  const errors = [];
  if (carryover.state !== "approved") {
    errors.push("state must be approved");
  }
  if (!carryover.source?.domain || !carryover.source?.context_key) {
    errors.push("source domain/context_key required");
  }
  if (!carryover.target?.domain || !carryover.target?.context_key) {
    errors.push("target domain/context_key required");
  }
  if (!carryover.consent_basis || carryover.consent_basis === "required") {
    errors.push("consent_basis must be explicit");
  }
  if (carryover.redaction?.applied !== true) {
    errors.push("redaction.applied must be true");
  }
  if (!carryover.artifact_id) {
    errors.push("artifact_id required");
  }
  if (errors.length > 0) {
    throw new Error(
      `Carryover rejected (${path.relative(memoryRoot, filePath)}): ${errors.join("; ")}`,
    );
  }
};

const createCarryoverRecord = (carryover, carryoverFile) => {
  const targetTier = String(carryover.target.domain);
  const targetScope = scopeForTier(targetTier);
  const targetContextKey = String(carryover.target.context_key);
  const artifactId = String(carryover.artifact_id);
  const retentionUntil =
    typeof carryover.retention_until === "string" && carryover.retention_until.length > 0
      ? carryover.retention_until
      : addDays(nowIso().slice(0, 10), retentionDaysForTier(targetTier));
  const date = retentionUntil.slice(0, 10);
  const contextSlug = `${slugify(targetContextKey)}-${hash8(targetContextKey)}`;
  const memoryId = `mem-${hash12(`carryover|${artifactId}|${targetTier}|${targetContextKey}`)}`;
  const noteRelativePath = path.posix.join(
    sectionForScope(targetScope),
    contextSlug,
    `${date}--carryover-${slugify(artifactId)}.md`,
  );
  const relativeCarryoverPath = path.relative(memoryRoot, carryoverFile).replaceAll(path.sep, "/");
  const sourceIds = unique(
    toJsonArray(carryover.provenance?.summary_ids)
      .map((id) => String(id).trim())
      .filter(Boolean),
  );
  const bulletText = toJsonArray(carryover.payload?.bullets)
    .map((line) => String(line).trim())
    .filter(Boolean);
  const title = String(carryover.payload?.title ?? "Carryover Artifact").trim();
  const text = unique([title, ...bulletText])
    .join(" ")
    .trim();
  const ttlDays = Math.max(
    1,
    Math.ceil((new Date(retentionUntil).getTime() - Date.now()) / (24 * 60 * 60 * 1000)),
  );

  const noteRecord = {
    memory_id: memoryId,
    schema_version: "stream-c-v1",
    tier: targetTier,
    scope: targetScope,
    context_key: targetContextKey,
    source: {
      raw_files: [relativeCarryoverPath],
      event_ids: sourceIds,
    },
    confidence: 0.8,
    ttl_days: ttlDays,
    retention_until: retentionUntil,
    sensitivity: targetTier === "person-private" ? ["private"] : ["internal"],
    created_at: nowIso(),
    updated_at: nowIso(),
    links: {
      timeline: [`timeline/${date}`],
      concepts: [],
    },
  };

  return {
    artifactId,
    memoryId,
    targetTier,
    targetScope,
    targetContextKey,
    date,
    noteRelativePath,
    noteRecord,
    text,
  };
};

const compile = async () => {
  const rawFiles = await listRawFiles();
  if (rawFiles.length === 0) {
    throw new Error("No raw JSONL files found. Run seed-sample or add files under memory/raw/");
  }
  const approvedCarryoverFiles = await findJsonFiles(carryoverApprovedRoot);

  const summaryRecords = [];
  const carryoverRecords = [];
  const entities = new Map();
  const timeline = new Map();

  for (const rawFile of rawFiles) {
    const events = await parseJsonl(rawFile);
    if (events.length === 0) {
      continue;
    }

    const summaryRecord = createSummaryRecord(events, rawFile);
    if (!summaryRecord) {
      continue;
    }

    const notePath = path.join(vaultRoot, ...summaryRecord.noteRelativePath.split("/"));
    const markdown = buildSummaryMarkdown(summaryRecord.noteRecord, summaryRecord.summary);
    await writeFile(notePath, markdown);

    const qmdRecord = {
      memory_id: summaryRecord.memoryId,
      schema_version: "stream-c-v1",
      domain: summaryRecord.tier,
      scope: summaryRecord.scope,
      context_key: summaryRecord.contextKey,
      source: {
        note_path: summaryRecord.noteRelativePath,
        raw_files: summaryRecord.noteRecord.source.raw_files,
      },
      confidence: Number(summaryRecord.noteRecord.confidence.toFixed(2)),
      ttl_days: summaryRecord.noteRecord.ttl_days,
      retention_until: summaryRecord.noteRecord.retention_until,
      artifact_type: "summary",
      sensitivity: summaryRecord.noteRecord.sensitivity,
      provenance: {
        source_file: summaryRecord.noteRecord.source.raw_files[0] ?? "",
        artifact_id: summaryRecord.memoryId,
      },
      text: summaryRecord.text,
    };
    await writeFile(
      path.join(qmdIngestRoot, `${summaryRecord.memoryId}.json`),
      `${JSON.stringify(qmdRecord, null, 2)}\n`,
    );

    for (const entityName of summaryRecord.summary.entities) {
      const entitySlug = `${slugify(entityName)}-${hash8(entityName)}`;
      const existing = entities.get(entitySlug) ?? {
        entity_id: `ent-${hash12(entityName)}`,
        entity_name: entityName,
        sources: [],
      };
      existing.sources.push(summaryRecord.noteRelativePath.replace(/\.md$/, ""));
      entities.set(entitySlug, existing);
    }

    const timelineEntries = timeline.get(summaryRecord.date) ?? [];
    timelineEntries.push({
      tier: summaryRecord.tier,
      context_key: summaryRecord.contextKey,
      note: summaryRecord.noteRelativePath.replace(/\.md$/, ""),
      memory_id: summaryRecord.memoryId,
    });
    timeline.set(summaryRecord.date, timelineEntries);

    summaryRecords.push(summaryRecord);
  }

  for (const carryoverFile of approvedCarryoverFiles) {
    const carryover = await parseCarryoverFile(carryoverFile);
    validateApprovedCarryover(carryover, carryoverFile);
    const carryoverRecord = createCarryoverRecord(carryover, carryoverFile);

    const notePath = path.join(vaultRoot, ...carryoverRecord.noteRelativePath.split("/"));
    const markdown = buildCarryoverMarkdown(carryoverRecord.noteRecord, carryover);
    await writeFile(notePath, markdown);

    const qmdRecord = {
      memory_id: carryoverRecord.memoryId,
      schema_version: "stream-c-v1",
      domain: carryoverRecord.targetTier,
      scope: carryoverRecord.targetScope,
      context_key: carryoverRecord.targetContextKey,
      source: {
        note_path: carryoverRecord.noteRelativePath,
        raw_files: carryoverRecord.noteRecord.source.raw_files,
      },
      confidence: Number(carryoverRecord.noteRecord.confidence.toFixed(2)),
      ttl_days: carryoverRecord.noteRecord.ttl_days,
      retention_until: carryoverRecord.noteRecord.retention_until,
      artifact_type: "carryover",
      sensitivity: carryoverRecord.noteRecord.sensitivity,
      provenance: {
        source_file: carryoverRecord.noteRecord.source.raw_files[0] ?? "",
        artifact_id: carryoverRecord.artifactId,
      },
      text: carryoverRecord.text,
    };
    await writeFile(
      path.join(qmdIngestRoot, `${carryoverRecord.memoryId}.json`),
      `${JSON.stringify(qmdRecord, null, 2)}\n`,
    );

    const timelineEntries = timeline.get(carryoverRecord.date) ?? [];
    timelineEntries.push({
      tier: carryoverRecord.targetTier,
      context_key: carryoverRecord.targetContextKey,
      note: carryoverRecord.noteRelativePath.replace(/\.md$/, ""),
      memory_id: carryoverRecord.memoryId,
    });
    timeline.set(carryoverRecord.date, timelineEntries);

    carryoverRecords.push(carryoverRecord);
  }

  for (const [entitySlug, entityRecord] of [...entities.entries()].toSorted((left, right) =>
    left[0].localeCompare(right[0]),
  )) {
    const conceptPath = path.join(vaultRoot, "entities", `${entitySlug}.md`);
    const sourceLinks = unique(entityRecord.sources)
      .toSorted((left, right) => left.localeCompare(right))
      .map((link) => `- [[${link}]]`)
      .join("\n");
    const markdown = `---\nentity_id: ${entityRecord.entity_id}\nentity_name: ${entityRecord.entity_name}\nschema_version: stream-c-v1\nupdated_at: ${nowIso()}\n---\n\n# ${entityRecord.entity_name}\n\n## Referenced By\n${sourceLinks || "- None"}\n`;
    await writeFile(conceptPath, markdown);
  }

  for (const [date, entries] of [...timeline.entries()].toSorted((left, right) =>
    left[0].localeCompare(right[0]),
  )) {
    const sortedEntries = entries.toSorted((left, right) => left.note.localeCompare(right.note));
    const markdown = `---\ntimeline_date: ${date}\nschema_version: stream-c-v1\nentry_count: ${sortedEntries.length}\nupdated_at: ${nowIso()}\n---\n\n# Timeline ${date}\n\n${sortedEntries
      .map(
        (entry) =>
          `- [[${entry.note}]] (${entry.tier}, context: \`${entry.context_key}\`, memory: \`${entry.memory_id}\`)`,
      )
      .join("\n")}\n`;
    await writeFile(path.join(vaultRoot, "timeline", `${date}.md`), markdown);
  }

  const manifest = {
    schema_version: "stream-c-v1",
    generated_at: nowIso(),
    raw_file_count: rawFiles.length,
    summary_count: summaryRecords.length,
    approved_carryover_count: carryoverRecords.length,
    entity_note_count: entities.size,
    timeline_note_count: timeline.size,
  };
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  console.log(
    `[memory-pipeline] compiled ${summaryRecords.length} summaries + ${carryoverRecords.length} approved carryovers from ${rawFiles.length} raw files`,
  );
};

const listRawFiles = async () => {
  const categories = ["global", "groups", "dm"];
  const files = [];
  for (const category of categories) {
    const categoryPath = path.join(rawRoot, category);
    const categoryFiles = await findJsonl(categoryPath);
    files.push(...categoryFiles);
  }
  files.sort((left, right) => left.localeCompare(right));
  return files;
};

const findJsonl = async (dirPath) => {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    const matches = [];
    for (const entry of entries) {
      const fullPath = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        matches.push(...(await findJsonl(fullPath)));
      } else if (entry.name.endsWith(".jsonl")) {
        matches.push(fullPath);
      }
    }
    return matches;
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
};

const findJsonFiles = async (dirPath) => {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    const matches = [];
    for (const entry of entries) {
      const fullPath = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        matches.push(...(await findJsonFiles(fullPath)));
      } else if (entry.name.endsWith(".json")) {
        matches.push(fullPath);
      }
    }
    matches.sort((left, right) => left.localeCompare(right));
    return matches;
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
};

const parseFrontmatter = (raw) => {
  if (!raw.startsWith("---\n")) {
    return {};
  }
  const end = raw.indexOf("\n---\n", 4);
  if (end === -1) {
    return {};
  }
  const block = raw.slice(4, end);
  const frontmatter = {};
  for (const line of block.split("\n")) {
    const separator = line.indexOf(":");
    if (separator === -1) {
      continue;
    }
    const key = line.slice(0, separator).trim();
    const value = line.slice(separator + 1).trim();
    frontmatter[key] = value;
  }
  return frontmatter;
};

const lint = async () => {
  const mdFiles = await findMarkdown(vaultRoot);
  const noteIndex = new Set(
    mdFiles.map((filePath) =>
      path.relative(vaultRoot, filePath).replaceAll(path.sep, "/").replace(/\.md$/, ""),
    ),
  );

  const brokenLinks = [];
  const entityLocations = new Map();
  const staleSummaries = [];
  const today = new Date().toISOString().slice(0, 10);

  for (const filePath of mdFiles) {
    const relative = path.relative(vaultRoot, filePath).replaceAll(path.sep, "/");
    const content = await fs.readFile(filePath, "utf8");
    const frontmatter = parseFrontmatter(content);

    const linkMatches = [...content.matchAll(/\[\[([^\]]+)\]\]/g)].map((match) => match[1]);
    for (const rawLink of linkMatches) {
      const [linkNoAlias] = rawLink.split("|");
      const [linkNoHeading] = linkNoAlias.split("#");
      const normalized = linkNoHeading.trim();
      if (!normalized) {
        continue;
      }
      if (!noteIndex.has(normalized)) {
        brokenLinks.push({
          note: relative,
          link: normalized,
        });
      }
    }

    if (relative.startsWith("entities/")) {
      const entityId = frontmatter.entity_id;
      if (entityId) {
        const paths = entityLocations.get(entityId) ?? [];
        paths.push(relative);
        entityLocations.set(entityId, paths);
      }
    }

    if (frontmatter.retention_until && frontmatter.retention_until < today) {
      staleSummaries.push({
        note: relative,
        retention_until: frontmatter.retention_until,
      });
    }
  }

  const duplicateEntities = [...entityLocations.entries()]
    .filter(([, paths]) => paths.length > 1)
    .map(([entityId, paths]) => ({ entity_id: entityId, notes: paths.toSorted() }));

  const report = {
    generated_at: nowIso(),
    notes_scanned: mdFiles.length,
    broken_links: brokenLinks,
    duplicate_entities: duplicateEntities,
    stale_summaries: staleSummaries,
  };

  await writeFile(path.join(lintDir, "latest-report.json"), `${JSON.stringify(report, null, 2)}\n`);

  const hasFailure =
    brokenLinks.length > 0 || duplicateEntities.length > 0 || staleSummaries.length > 0;
  if (hasFailure) {
    console.error(
      `[memory-pipeline] lint failed: broken_links=${brokenLinks.length}, duplicate_entities=${duplicateEntities.length}, stale_summaries=${staleSummaries.length}`,
    );
    process.exitCode = 1;
    return;
  }

  console.log(`[memory-pipeline] lint passed: ${mdFiles.length} notes scanned`);
};

const findMarkdown = async (dirPath) => {
  try {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    const matches = [];
    for (const entry of entries) {
      const fullPath = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        matches.push(...(await findMarkdown(fullPath)));
      } else if (entry.name.endsWith(".md")) {
        matches.push(fullPath);
      }
    }
    matches.sort((left, right) => left.localeCompare(right));
    return matches;
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
};

const query = async (options) => {
  const tier = options.tier;
  const contextKey = options["context-key"];
  const limit = Number.parseInt(options.limit ?? "5", 10);

  if (!tier || !contextKey) {
    throw new Error("query requires --tier and --context-key");
  }

  const records = await loadQmdRecords();
  const matched = records
    .filter((record) => record.domain === tier && record.context_key === contextKey)
    .toSorted((left, right) => left.memory_id.localeCompare(right.memory_id))
    .slice(0, Number.isFinite(limit) && limit > 0 ? limit : 5);

  console.log(
    JSON.stringify(
      {
        tier,
        context_key: contextKey,
        matches: matched,
      },
      null,
      2,
    ),
  );
};

const loadQmdRecords = async () => {
  const entries = await fs.readdir(qmdIngestRoot, { withFileTypes: true });
  const records = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) {
      continue;
    }
    const filePath = path.join(qmdIngestRoot, entry.name);
    const content = await fs.readFile(filePath, "utf8");
    records.push(JSON.parse(content));
  }
  return records;
};

const seedSample = async () => {
  const samples = [
    {
      filePath: path.join(rawRoot, "groups", "telegram-100777000111-topic-17", "2026-04-03.jsonl"),
      lines: [
        {
          event_id: "evt-group-0001",
          timestamp: "2026-04-03T13:05:00Z",
          surface: "group",
          channel: "telegram",
          context_key: "telegram:-100777000111:17",
          actor: "alice",
          text: "Canary smoke is green for OpenClaw 2026.4.1 in the ops group.",
          entities: ["OpenClaw", "canary", "smoke-suite"],
          labels: ["update"],
          sensitivity: ["internal"],
          confidence: 0.9,
        },
        {
          event_id: "evt-group-0002",
          timestamp: "2026-04-03T13:11:00Z",
          surface: "group",
          channel: "telegram",
          context_key: "telegram:-100777000111:17",
          actor: "bob",
          text: "Decision: keep auto-promotion off until weekly hygiene stays stable.",
          entities: ["auto-promotion", "weekly-hygiene"],
          labels: ["decision"],
          sensitivity: ["internal"],
          confidence: 0.86,
        },
        {
          event_id: "evt-group-0003",
          timestamp: "2026-04-03T13:25:00Z",
          surface: "group",
          channel: "telegram",
          context_key: "telegram:-100777000111:17",
          actor: "carol",
          text: "Open question: should we increase digest frequency for release anomalies?",
          entities: ["release-digest", "anomaly-detection"],
          labels: ["question"],
          sensitivity: ["internal"],
          confidence: 0.79,
        },
      ],
    },
    {
      filePath: path.join(rawRoot, "dm", "telegram-99887766", "2026-04-03.jsonl"),
      lines: [
        {
          event_id: "evt-dm-0001",
          timestamp: "2026-04-03T15:04:00Z",
          surface: "dm",
          channel: "telegram",
          context_key: "telegram:99887766",
          actor: "operator",
          text: "Personal note: prefers concise release digests with one-line rollback status.",
          entities: ["release-digest", "rollback-status"],
          labels: ["preference"],
          sensitivity: ["private"],
          confidence: 0.92,
        },
        {
          event_id: "evt-dm-0002",
          timestamp: "2026-04-03T15:07:00Z",
          surface: "dm",
          channel: "telegram",
          context_key: "telegram:99887766",
          actor: "operator",
          text: "Question: can DM memory stay isolated from group chatter unless I opt in?",
          entities: ["dm-memory", "consent-policy"],
          labels: ["question"],
          sensitivity: ["private"],
          confidence: 0.95,
        },
      ],
    },
    {
      filePath: path.join(rawRoot, "global", "ops-control-plane", "2026-04-03.jsonl"),
      lines: [
        {
          event_id: "evt-global-0001",
          timestamp: "2026-04-03T18:00:00Z",
          surface: "global",
          channel: "ops",
          context_key: "ops:release-intel",
          actor: "system",
          text: "Global fact: release watcher, daily digest, and weekly hygiene are all enabled.",
          entities: ["release-watcher", "daily-digest", "weekly-hygiene"],
          labels: ["update"],
          sensitivity: ["internal"],
          confidence: 0.88,
        },
        {
          event_id: "evt-global-0002",
          timestamp: "2026-04-03T18:06:00Z",
          surface: "global",
          channel: "ops",
          context_key: "ops:release-intel",
          actor: "system",
          text: "Decision: treat Stream C memory as markdown-first with deterministic lint checks.",
          entities: ["Stream-C", "lint-checks"],
          labels: ["decision"],
          sensitivity: ["internal"],
          confidence: 0.84,
        },
      ],
    },
  ];

  let created = 0;
  for (const sample of samples) {
    const existing = await readIfExists(sample.filePath);
    if (existing !== null) {
      continue;
    }
    const content = `${sample.lines.map((line) => JSON.stringify(line)).join("\n")}\n`;
    await writeFile(sample.filePath, content);
    created += 1;
  }

  console.log(`[memory-pipeline] sample raw files created: ${created}`);
};

const seedCarryoverSample = async () => {
  const samplePath = path.join(carryoverApprovedRoot, "co-group-to-global-0001.json");
  const existing = await readIfExists(samplePath);
  if (existing !== null) {
    console.log("[memory-pipeline] sample carryover already exists");
    return;
  }

  const sample = {
    artifact_id: "co-group-to-global-0001",
    source: {
      domain: "group-shared",
      context_key: "telegram:-100777000111:17",
    },
    target: {
      domain: "global-shared",
      context_key: "ops:release-intel",
    },
    state: "approved",
    consent_basis: "operator_policy_approved",
    redaction: {
      applied: true,
      labels: ["pii", "secrets"],
    },
    retention_until: "2026-05-15",
    provenance: {
      summary_ids: ["mem-26e7ce440133"],
      event_range: "2026-04-03T13:05:00Z..2026-04-03T13:25:00Z",
    },
    payload: {
      title: "Global carryover: canary posture",
      bullets: [
        "Ops group confirmed canary smoke green for OpenClaw 2026.4.1.",
        "Auto-promotion remains disabled pending stable weekly hygiene trend.",
      ],
    },
  };

  await writeFile(samplePath, `${JSON.stringify(sample, null, 2)}\n`);
  console.log("[memory-pipeline] sample approved carryover created: co-group-to-global-0001");
};

const demo = async () => {
  const groupKey = "telegram:-100777000111:17";
  const dmKey = "telegram:99887766";

  const records = await loadQmdRecords();
  const groupMatches = records.filter(
    (record) => record.domain === "group-shared" && record.context_key === groupKey,
  );
  const dmMatches = records.filter(
    (record) => record.domain === "person-private" && record.context_key === dmKey,
  );
  const blockedMatches = records.filter(
    (record) => record.domain === "person-private" && record.context_key === groupKey,
  );

  const payload = {
    group_query: {
      tier: "group-shared",
      context_key: groupKey,
      hit_count: groupMatches.length,
      memory_ids: groupMatches.map((record) => record.memory_id),
    },
    dm_query: {
      tier: "person-private",
      context_key: dmKey,
      hit_count: dmMatches.length,
      memory_ids: dmMatches.map((record) => record.memory_id),
    },
    scoped_separation_check: {
      attempted_tier: "person-private",
      attempted_context_key: groupKey,
      hit_count: blockedMatches.length,
      expected: 0,
      pass: blockedMatches.length === 0,
    },
  };

  console.log(JSON.stringify(payload, null, 2));
};

const main = async () => {
  const [command, ...argv] = process.argv.slice(2);

  if (!command) {
    console.log(usage);
    process.exit(1);
    return;
  }

  const options = parseArgs(argv);

  if (command === "seed-sample") {
    await seedSample();
    return;
  }

  if (command === "compile") {
    await compile();
    return;
  }

  if (command === "seed-carryover-sample") {
    await seedCarryoverSample();
    return;
  }

  if (command === "lint") {
    await lint();
    return;
  }

  if (command === "query") {
    await query(options);
    return;
  }

  if (command === "demo") {
    await demo();
    return;
  }

  console.log(usage);
  process.exit(1);
};

await main();
