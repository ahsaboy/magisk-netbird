<script setup>
import { computed, useAttrs } from "vue";
import { cva } from "class-variance-authority";
import { cn } from "@/lib/utils";

const props = defineProps({ variant: { type: String, default: "default" }, size: { type: String, default: "default" }, type: { type: String, default: "button" } });
const attrs = useAttrs();
const variants = cva("inline-flex shrink-0 items-center justify-center gap-1.5 whitespace-nowrap rounded-md text-xs font-semibold transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0", {
  variants: {
    variant: {
      default: "bg-primary text-primary-foreground shadow-sm hover:bg-primary/90",
      destructive: "bg-destructive text-white shadow-sm hover:bg-destructive/90",
      outline: "border border-input bg-background hover:bg-accent hover:text-accent-foreground",
      secondary: "bg-secondary text-secondary-foreground hover:bg-secondary/80",
      ghost: "hover:bg-accent hover:text-accent-foreground",
      link: "text-primary underline-offset-4 hover:underline"
    },
    size: {
      default: "h-10 px-3.5 py-2",
      sm: "h-8 rounded-md px-2.5 text-[11px]",
      lg: "h-11 rounded-md px-5",
      icon: "size-9"
    }
  },
  defaultVariants: { variant: "default", size: "default" }
});
const classes = computed(() => cn(variants({ variant: props.variant, size: props.size }), attrs.class));
</script>

<template><button v-bind="attrs" :type="type" :class="classes"><slot /></button></template>
