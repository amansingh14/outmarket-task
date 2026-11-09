import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.jsx";

const idea = (id, content) => ({ id, content, created_at: "2026-11-09T10:00:00Z" });

function mockFetch(handlers) {
  return vi.fn(async (url, opts = {}) => {
    const key = `${opts.method || "GET"} ${url}`;
    const h = handlers[key];
    if (!h) throw new Error(`unexpected request ${key}`);
    const { status = 200, body } = typeof h === "function" ? h(opts) : h;
    return { ok: status < 400, status, json: async () => body };
  });
}

describe("Idea Board", () => {
  beforeEach(() => vi.restoreAllMocks());
  afterEach(() => vi.unstubAllGlobals());

  it("lists ideas from the API", async () => {
    vi.stubGlobal("fetch", mockFetch({ "GET /api/ideas": { body: [idea(2, "Second"), idea(1, "First")] } }));
    render(<App />);
    expect(await screen.findByText("Second")).toBeInTheDocument();
    expect(screen.getByText("First")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Ideas (2)" })).toBeInTheDocument();
  });

  it("shows an empty state", async () => {
    vi.stubGlobal("fetch", mockFetch({ "GET /api/ideas": { body: [] } }));
    render(<App />);
    expect(await screen.findByText(/No ideas yet/)).toBeInTheDocument();
  });

  it("submits a trimmed idea and prepends it", async () => {
    const fetch = mockFetch({
      "GET /api/ideas": { body: [idea(1, "Old")] },
      "POST /api/ideas": (opts) => ({ status: 201, body: idea(2, JSON.parse(opts.body).content) }),
    });
    vi.stubGlobal("fetch", fetch);
    render(<App />);
    await screen.findByText("Old");
    const box = screen.getByLabelText("New idea");
    const button = screen.getByRole("button", { name: "Add idea" });
    expect(button).toBeDisabled(); // nothing typed yet
    await userEvent.type(box, "  Ship it  ");
    await userEvent.click(button);
    expect(await screen.findByText("Ship it")).toBeInTheDocument();
    expect(JSON.parse(fetch.mock.calls[1][1].body)).toEqual({ content: "Ship it" });
    expect(box).toHaveValue("");
    const items = screen.getAllByRole("listitem").map((li) => li.querySelector("p").textContent);
    expect(items).toEqual(["Ship it", "Old"]);
  });

  it("reports API errors instead of failing silently", async () => {
    vi.stubGlobal("fetch", mockFetch({ "GET /api/ideas": { status: 503, body: {} } }));
    render(<App />);
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("Failed to load ideas (503)"));
  });
});
