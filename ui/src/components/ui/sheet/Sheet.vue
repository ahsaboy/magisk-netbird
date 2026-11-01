<script setup>
import { DrawerRoot } from "reka-ui";

const props = defineProps({ open: { type: Boolean, default: false } });
const emit = defineEmits(["update:open"]);
</script>

<template>
  <DrawerRoot :open="props.open" swipe-direction="down" @update:open="emit('update:open', $event)">
    <slot />
  </DrawerRoot>
</template>
