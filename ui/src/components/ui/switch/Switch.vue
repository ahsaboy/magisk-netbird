<script setup>
import { computed, useAttrs } from "vue";
import { cn } from "@/lib/utils";

defineOptions({ inheritAttrs: false });
const props = defineProps({
  modelValue: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  ariaLabel: { type: String, default: "" }
});
const emit = defineEmits(["update:modelValue", "change"]);
const attrs = useAttrs();
const classes = computed(() => cn("ui-switch", props.modelValue ? "is-checked" : "", attrs.class));
function toggle() {
  if (props.disabled) return;
  const value = !props.modelValue;
  emit("update:modelValue", value);
  emit("change", value);
}
</script>

<template>
  <button
    v-bind="attrs"
    type="button"
    role="switch"
    :class="classes"
    :aria-checked="props.modelValue"
    :aria-label="props.ariaLabel || undefined"
    :disabled="props.disabled"
    @click="toggle"
  >
    <span class="ui-switch-thumb" />
  </button>
</template>
