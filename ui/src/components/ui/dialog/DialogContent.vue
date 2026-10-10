<script setup>
import { computed, useAttrs } from "vue";
import { DialogClose, DialogContent as RekaDialogContent, DialogOverlay, DialogPortal } from "reka-ui";
import { X } from "@lucide/vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const props = defineProps({ closeLabel: { type: String, default: "Close dialog" } });
const attrs = useAttrs();
const classes = computed(() => cn("dialog-panel", attrs.class));
</script>

<template>
  <DialogPortal>
    <DialogOverlay class="dialog-overlay" />
    <RekaDialogContent v-bind="attrs" :class="classes" role="alertdialog" aria-modal="true">
      <slot />
      <DialogClose as-child>
        <button class="dialog-close" type="button" :aria-label="props.closeLabel"><X :size="16" /></button>
      </DialogClose>
    </RekaDialogContent>
  </DialogPortal>
</template>
