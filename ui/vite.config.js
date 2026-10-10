import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [vue(), tailwindcss()],
  resolve: {
    alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) }
  },
  base: "./",
  server: {
    fs: { allow: [".."] }
  },
  build: {
    outDir: "../webroot",
    emptyOutDir: false,
    assetsDir: "assets",
    rollupOptions: {
      output: {
        entryFileNames: "assets/netbird.js",
        chunkFileNames: "assets/chunks/[name]-[hash].js",
        assetFileNames: (asset) => asset.name?.endsWith(".css")
          ? "assets/netbird.css"
          : "assets/[name]-[hash][extname]"
      }
    }
  }
});
