import { useEffect, useState } from "react";

const MAX = 500;

export default function App() {
  const [ideas, setIdeas] = useState([]);
  const [content, setContent] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  async function load() {
    try {
      const res = await fetch("/api/ideas");
      if (!res.ok) throw new Error(`Failed to load ideas (${res.status})`);
      setIdeas(await res.json());
      setError("");
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function submit(e) {
    e.preventDefault();
    const trimmed = content.trim();
    if (!trimmed) return;
    setSaving(true);
    try {
      const res = await fetch("/api/ideas", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: trimmed }),
      });
      if (!res.ok) throw new Error(`Could not save idea (${res.status})`);
      const idea = await res.json();
      setIdeas((prev) => [idea, ...prev]);
      setContent("");
      setError("");
    } catch (e) {
      setError(e.message);
    } finally {
      setSaving(false);
    }
  }

  return (
    <main className="container">
      <header>
        <h1>Idea Board</h1>
        <p className="subtitle">Write down an idea before you forget it.</p>
      </header>

      <form onSubmit={submit} className="card">
        <label htmlFor="idea">New idea</label>
        <textarea
          id="idea"
          value={content}
          maxLength={MAX}
          rows={3}
          placeholder="My new idea…"
          onChange={(e) => setContent(e.target.value)}
        />
        <div className="row">
          <span className="muted">
            {content.length}/{MAX}
          </span>
          <button type="submit" disabled={saving || !content.trim()}>
            {saving ? "Saving…" : "Add idea"}
          </button>
        </div>
      </form>

      {error && (
        <p role="alert" className="error">
          {error}
        </p>
      )}

      <section>
        <h2>Ideas ({ideas.length})</h2>
        {loading ? (
          <p className="muted">Loading…</p>
        ) : ideas.length === 0 ? (
          <p className="muted">No ideas yet. Add the first one.</p>
        ) : (
          <ul className="ideas">
            {ideas.map((idea) => (
              <li key={idea.id} className="card">
                <p>{idea.content}</p>
                <time className="muted" dateTime={idea.created_at}>
                  {new Date(idea.created_at).toLocaleString()}
                </time>
              </li>
            ))}
          </ul>
        )}
      </section>
      <footer className="muted">Served from: {window.location.host}</footer>
    </main>
  );
}
