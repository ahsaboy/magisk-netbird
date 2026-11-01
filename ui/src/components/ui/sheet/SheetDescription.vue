<script setup>
import { useAttrs } from "vue";
import { DrawerDescription as RekaDrawerDescription } from "reka-ui";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
</script>

<template><RekaDrawerDescription v-bind="attrs" :class="cn('sheet-description dialog-description', attrs.class)"><slot /></RekaDrawerDescription></template>
