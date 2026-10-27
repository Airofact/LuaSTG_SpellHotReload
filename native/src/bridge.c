/* Probe-private ABI adaptation only. No Lua C API or language rules. */
#include <stddef.h>
#include <tree_sitter/api.h>
#include "alloc.h"

typedef struct DimsInfo {
  const char *type;
  uint32_t symbol, grammar_symbol, named, extra, error, missing, has_error;
  uint32_t start_byte, end_byte, start_row, start_column, end_row, end_column;
  uint32_t children;
} DimsInfo;

uint32_t dims_layout(uint32_t *out, uint32_t capacity) {
  const uint32_t values[] = {
    sizeof(void *), sizeof(TSNode), offsetof(TSNode, id), offsetof(TSNode, tree),
    sizeof(TSPoint), offsetof(TSPoint, column),
    sizeof(TSInputEdit), offsetof(TSInputEdit, old_end_byte),
    offsetof(TSInputEdit, new_end_byte), offsetof(TSInputEdit, start_point),
    offsetof(TSInputEdit, old_end_point), offsetof(TSInputEdit, new_end_point),
    sizeof(TSRange), offsetof(TSRange, end_point),
    offsetof(TSRange, start_byte), offsetof(TSRange, end_byte),
    sizeof(DimsInfo), offsetof(DimsInfo, symbol), offsetof(DimsInfo, children),
    TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION, TREE_SITTER_LANGUAGE_VERSION
  };
  const uint32_t count = sizeof(values) / sizeof(values[0]);
  if (capacity >= count) {
    for (uint32_t i = 0; i < count; i++) out[i] = values[i];
  }
  return count;
}
void dims_root(const TSTree *tree, TSNode *out) {
  *out = ts_tree_root_node(tree);
}
void dims_child(const TSNode *node, uint32_t index, TSNode *out) {
  *out = ts_node_child(*node, index);
}
const char *dims_field(const TSNode *node, uint32_t index) {
  return ts_node_field_name_for_child(*node, index);
}
void dims_info(const TSNode *node, DimsInfo *out) {
  const TSPoint start = ts_node_start_point(*node);
  const TSPoint end = ts_node_end_point(*node);
  *out = (DimsInfo) {
    ts_node_type(*node), ts_node_symbol(*node), ts_node_grammar_symbol(*node),
    ts_node_is_named(*node), ts_node_is_extra(*node), ts_node_is_error(*node),
    ts_node_is_missing(*node), ts_node_has_error(*node),
    ts_node_start_byte(*node), ts_node_end_byte(*node),
    start.row, start.column, end.row, end.column, ts_node_child_count(*node)
  };
}
void dims_ranges_free(TSRange *ranges) {
  ts_free(ranges);
}
