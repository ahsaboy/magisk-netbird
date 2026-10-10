<script setup>
import { computed, useAttrs } from "vue";
import { cn } from "@/lib/utils";

const props = defineProps({ modelValue: { type: [String, Number], default: "" }, class: { type: null, default: "" } });
const emit = defineEmits(["update:modelValue"]);
const attrs = useAttrs();
const classes = computed(() => cn("flex h-10 w-full min-w-0 rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm outline-none placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50", props.class, attrs.class));
</script>

<template><input v-bind="attrs" :value="modelValue" :class="classes" @input="emit('update:modelValue', $event.target.value)" /></template>
