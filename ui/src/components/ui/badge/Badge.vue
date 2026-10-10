<script setup>
import { computed, useAttrs } from "vue";
import { cva } from "class-variance-authority";
import { cn } from "@/lib/utils";

const props = defineProps({ variant: { type: String, default: "default" } });
const attrs = useAttrs();
const variants = cva("inline-flex w-fit shrink-0 items-center justify-center gap-1 overflow-hidden whitespace-nowrap rounded-md border px-2 py-0.5 text-[10px] font-semibold transition-colors focus:outline-none focus:ring-2 focus:ring-ring", {
  variants: {
    variant: {
      default: "border-transparent bg-primary text-primary-foreground",
      secondary: "border-transparent bg-secondary text-secondary-foreground",
      destructive: "border-transparent bg-destructive text-white",
      outline: "border-border bg-transparent text-foreground"
    }
  },
  defaultVariants: { variant: "default" }
});
const classes = computed(() => cn(variants({ variant: props.variant }), attrs.class));
</script>

<template><span v-bind="attrs" :class="classes"><slot /></span></template>
