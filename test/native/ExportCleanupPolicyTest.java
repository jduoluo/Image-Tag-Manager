package com.example.image_tag_manager;
import java.util.*;
public final class ExportCleanupPolicyTest {
    static Map<String, String> row() {
        Map<String, String> row = new HashMap<>();
        row.put("owner_package_name", "app"); row.put("relative_path", "Pictures/TagQuickShare/");
        row.put("is_pending", "0"); row.put("_display_name", "[测试]a.jpg");
        row.put("_data", "/storage/emulated/0/Pictures/TagQuickShare/[测试]a.jpg");
        row.put("_size", "78"); row.put("_id", "1"); row.put("generation_modified", "9");
        return row;
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        Map<String, String> before = row();
        check(ExportCleanupPolicy.eligible(before, "app"));
        for (String field : List.of("owner_package_name", "relative_path", "_data", "is_pending")) {
            Map<String, String> changed = row(); changed.put(field, "other");
            check(!ExportCleanupPolicy.eligible(changed, "app"));
        }
        check(ExportCleanupPolicy.unchanged(before, row(), "inode", "inode", "app"));
        check(!ExportCleanupPolicy.unchanged(before, row(), "inode", "replaced", "app"));
        for (String field : List.of("_size", "generation_modified", "_id", "_display_name")) {
            Map<String, String> changed = row(); changed.put(field, "changed");
            check(!ExportCleanupPolicy.unchanged(before, changed, "inode", "inode", "app"));
        }
        Map<String, String> unknown = row(); unknown.put("owner_package_name", null);
        check(!ExportCleanupPolicy.eligible(unknown, "app"));
        Map<String, String> temporary = row(); temporary.put("_display_name", "~itm-test.jpg");
        temporary.put("_data", "/storage/emulated/0/Pictures/TagQuickShare/~itm-test.jpg");
        check(!ExportCleanupPolicy.eligible(temporary, "app"));
        check(ExportCleanupPolicy.selectionAllowed(Set.of(1L, 2L), List.of(1L)));
        check(!ExportCleanupPolicy.selectionAllowed(Set.of(1L), List.of(2L)));
        check(!ExportCleanupPolicy.selectionAllowed(Set.of(1L), List.of(1L, 1L)));
        check(!ExportCleanupPolicy.selectionAllowed(Set.of(1L), List.of()));
        check(!ExportCleanupPolicy.selectionAllowed(Set.of(1L), Collections.nCopies(51, 1L)));
        System.out.println("Export cleanup policy checks passed: ownership, exact scope, pending, replacement, metadata changes, unknown owner, temporary names and selection bounds.");
    }
}
