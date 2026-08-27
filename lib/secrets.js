// Secret Manager access — Directive 1: keys are NEVER hardcoded and NEVER sent to the client.
// The Gemini API key is fetched at runtime from Google Cloud Secret Manager and cached in memory.
import { SecretManagerServiceClient } from "@google-cloud/secret-manager";

const client = new SecretManagerServiceClient();
const SECRET_NAME = process.env.GEMINI_SECRET_NAME || "GEMINI_API_KEY";

// In-memory cache so we don't hit Secret Manager on every request.
let cachedKey = null;
let cachedAt = 0;
const TTL_MS = 10 * 60 * 1000; // refresh every 10 minutes

let projectIdPromise = null;

// On Cloud Run the project id is not injected as an env var, so fall back to the
// metadata server. Set GOOGLE_CLOUD_PROJECT locally to skip the lookup.
async function getProjectId() {
  const fromEnv =
    process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT;
  if (fromEnv) return fromEnv;

  if (!projectIdPromise) {
    projectIdPromise = (async () => {
      const res = await fetch(
        "http://metadata.google.internal/computeMetadata/v1/project/project-id",
        { headers: { "Metadata-Flavor": "Google" } }
      );
      if (!res.ok) throw new Error("metadata_project_id_unavailable");
      return (await res.text()).trim();
    })().catch((e) => {
      projectIdPromise = null; // allow a retry on the next request
      throw e;
    });
  }
  return projectIdPromise;
}

export async function getGeminiApiKey() {
  const now = Date.now();
  if (cachedKey && now - cachedAt < TTL_MS) return cachedKey;

  const projectId = await getProjectId();
  const name = `projects/${projectId}/secrets/${SECRET_NAME}/versions/latest`;
  const [version] = await client.accessSecretVersion({ name });
  const payload = version?.payload?.data?.toString("utf8");

  if (!payload) throw new Error("Empty secret payload from Secret Manager.");

  cachedKey = payload.trim();
  cachedAt = now;
  return cachedKey;
}
