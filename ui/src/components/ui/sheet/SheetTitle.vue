<script setup>
import { useAttrs } from "vue";
import { DrawerTitle as RekaDrawerTitle } from "reka-ui";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
</script>

<template><RekaDrawerTitle v-bind="attrs" :class="cn('sheet-title dialog-title', attrs.class)"><slot /></RekaDrawerTitle></template>
