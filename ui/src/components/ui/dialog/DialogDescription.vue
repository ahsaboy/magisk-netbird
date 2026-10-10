<script setup>
import { useAttrs } from "vue";
import { DialogDescription as RekaDialogDescription } from "reka-ui";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
</script>

<template><RekaDialogDescription v-bind="attrs" :class="cn('dialog-description', attrs.class)"><slot /></RekaDialogDescription></template>
