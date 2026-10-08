// KernelSU WebUI bridge, based on the official `kernelsu` npm package.
let callbackCounter = 0;

function callbackName(prefix) {
  return `${prefix}_callback_${Date.now()}_${callbackCounter++}`;
}

export function exec(command, options = {}) {
  return new Promise((resolve, reject) => {
    const name = callbackName("exec");
    window[name] = (errno, stdout, stderr) => {
      delete window[name];
      resolve({ errno, stdout, stderr });
    };
    try {
      if (!window.ksu || typeof window.ksu.exec !== "function") {
        throw new Error("KernelSU WebUI API is unavailable");
      }
      window.ksu.exec(command, JSON.stringify(options), name);
    } catch (error) {
      delete window[name];
      reject(error);
    }
  });
}

export function toast(message) {
  if (window.ksu && typeof window.ksu.toast === "function") {
    window.ksu.toast(message);
  }
}
