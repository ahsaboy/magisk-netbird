<script setup>
import { computed, useAttrs } from "vue";
import { DrawerClose, DrawerContent as RekaDrawerContent, DrawerHandle, DrawerOverlay, DrawerPortal } from "reka-ui";
import { X } from "@lucide/vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const props = defineProps({ closeLabel: { type: String, default: "Close sheet" } });
const attrs = useAttrs();
const classes = computed(() => cn("sheet-panel", attrs.class));
</script>

<template>
  <DrawerPortal>
    <DrawerOverlay class="sheet-overlay" />
    <RekaDrawerContent v-bind="attrs" :class="classes">
      <DrawerHandle class="sheet-handle-wrap"><span class="sheet-handle" /></DrawerHandle>
      <slot />
      <DrawerClose as-child>
        <button class="sheet-close" type="button" :aria-label="props.closeLabel"><X :size="16" /></button>
      </DrawerClose>
    </RekaDrawerContent>
  </DrawerPortal>
</template>
