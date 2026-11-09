import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In dev, proxy /api to the backend so the browser only ever talks to one origin,
// exactly like production (where nginx does the proxying).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": process.env.VITE_API_PROXY || "http://localhost:8000" },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test-setup.js"],
  },
});
