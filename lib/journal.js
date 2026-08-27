// Firestore data access. Directive 3: every path is namespaced under users/{uid}.
// The uid ALWAYS comes from the verified token (see index.js), never from the request body.
//
// Collections:  users/{uid}/memories   sealed journal entries
//               users/{uid}/owlpost    weekly reflections
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const db = () => getFirestore();

function memoriesCol(uid) {
  return db().collection("users").doc(uid).collection("memories");
}

export async function sealMemory(uid, data) {
  const doc = {
    uid, // audit field — must equal the collection owner
    title: data.title,
    summary: data.summary,
    inscription: data.inscription, // the full conversation, as written on the page
    humour: data.humour,
    humourScore: data.humourScore,
    threads: data.threads || [],
    resolutions: data.resolutions || [],
    embedding: data.embedding || [],
    createdAt: FieldValue.serverTimestamp(),
    dayKey: data.dayKey, // YYYY-MM-DD in the writer's local time, for the vigil count
  };
  const ref = await memoriesCol(uid).add(doc);
  return ref.id;
}

export async function recallMemories(uid, limit = 50) {
  const snap = await memoriesCol(uid).orderBy("createdAt", "desc").limit(limit).get();
  return snap.docs.map((d) => {
    const m = d.data();
    return {
      id: d.id,
      title: m.title,
      summary: m.summary,
      humour: m.humour,
      humourScore: m.humourScore,
      threads: m.threads || [],
      resolutions: m.resolutions || [],
      createdAt: m.createdAt?.toMillis?.() || null,
      dayKey: m.dayKey || null,
    };
  });
}

// Divination: pull memories with embeddings, rank by cosine similarity in-process.
export async function divineMemories(uid, queryVec, topK = 5) {
  const snap = await memoriesCol(uid).orderBy("createdAt", "desc").limit(200).get();
  return snap.docs
    .map((d) => {
      const m = d.data();
      if (!Array.isArray(m.embedding) || m.embedding.length === 0) return null;
      return {
        id: d.id,
        title: m.title,
        summary: m.summary,
        humour: m.humour,
        humourScore: m.humourScore || 5,
        createdAt: m.createdAt?.toMillis?.() || null,
        score: cosine(queryVec, m.embedding),
      };
    })
    .filter(Boolean)
    .sort((a, b) => b.score - a.score)
    .slice(0, topK);
}

// The humours: emotional trend across recent memories.
export async function humourSeries(uid, limit = 60) {
  const snap = await memoriesCol(uid).orderBy("createdAt", "desc").limit(limit).get();
  return snap.docs
    .map((d) => {
      const m = d.data();
      return { t: m.createdAt?.toMillis?.() || null, humourScore: m.humourScore || null, humour: m.humour || "neutral" };
    })
    .filter((x) => x.t && x.humourScore)
    .reverse();
}

// The vigil: consecutive nights ending today/yesterday that carry at least one memory.
export async function computeVigil(uid, todayKey) {
  const snap = await memoriesCol(uid).orderBy("createdAt", "desc").limit(200).get();
  const nights = new Set(snap.docs.map((d) => d.data().dayKey).filter(Boolean));
  let vigil = 0;
  const cursor = new Date(todayKey + "T00:00:00Z");
  // The vigil stays lit if today has no memory yet but yesterday did.
  if (!nights.has(todayKey)) cursor.setUTCDate(cursor.getUTCDate() - 1);
  while (nights.has(toKey(cursor))) {
    vigil += 1;
    cursor.setUTCDate(cursor.getUTCDate() - 1);
  }
  return vigil;
}

export async function recentThreads(uid, limit = 10) {
  const snap = await memoriesCol(uid).orderBy("createdAt", "desc").limit(limit).get();
  const counts = {};
  snap.docs.forEach((d) => (d.data().threads || []).forEach((t) => (counts[t] = (counts[t] || 0) + 1)));
  return Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([t]) => t);
}

export async function saveOwlPost(uid, post) {
  await db().collection("users").doc(uid).collection("owlpost").add({
    uid,
    reflection: post.reflection,
    prompts: post.prompts || [],
    createdAt: FieldValue.serverTimestamp(),
  });
}

export async function weekMemories(uid) {
  const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const snap = await memoriesCol(uid).orderBy("createdAt", "desc").limit(50).get();
  return snap.docs
    .map((d) => d.data())
    .filter((m) => (m.createdAt?.toMillis?.() || 0) >= weekAgo)
    .map((m) => ({ title: m.title, summary: m.summary, humour: m.humour, humourScore: m.humourScore }));
}

export async function listActiveUserIds() {
  const docs = await db().collection("users").listDocuments();
  return docs.map((d) => d.id);
}

function cosine(a, b) {
  let dot = 0, na = 0, nb = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na === 0 || nb === 0) return 0;
  return dot / (Math.sqrt(na) * Math.sqrt(nb));
}

function toKey(d) {
  return d.toISOString().slice(0, 10);
}
