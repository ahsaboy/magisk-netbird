<script setup>
import { useAttrs } from "vue";
import { DialogTitle as RekaDialogTitle } from "reka-ui";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
</script>

<template><RekaDialogTitle v-bind="attrs" :class="cn('dialog-title', attrs.class)"><slot /></RekaDialogTitle></template>
