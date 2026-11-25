<script>
export default {
  props: {
    headerTitle: { type: String, default: '' },
    headerContent: { type: String, default: '' },
    totalRulesCount: { type: Number, default: null },
  },
};
</script>

<template>
  <div class="flex flex-col gap-1.5 w-full items-start mb-4">
    <div class="flex items-center gap-2 w-full">
      <h2 class="text-heading-1 text-n-slate-12 break-words">
        {{ headerTitle }}
      </h2>
      <span v-if="totalRulesCount !== null" class="text-body-main text-n-slate-11">
        Total Rules: {{ totalRulesCount }}
      </span>
      <slot name="suffix" />
    </div>
    <p
      v-dompurify-html="headerContent"
      class="text-body-main w-full text-n-slate-11"
    />
    <slot />
  </div>
</template>
