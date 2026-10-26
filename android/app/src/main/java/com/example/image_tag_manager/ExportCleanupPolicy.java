package com.example.image_tag_manager;

import java.util.*;

/** Pure policy shared by preview and deletion rechecks. No filesystem side effects. */
final class ExportCleanupPolicy {
    static boolean eligible(Map<String, String> row, String owner) {
        String name = row.get("_display_name");
        String path = row.get("_data");
        String size = row.get("_size");
        return owner.equals(row.get("owner_package_name")) &&
            "Pictures/TagQuickShare/".equals(row.get("relative_path")) &&
            "0".equals(row.get("is_pending")) && name != null && !name.isEmpty() &&
            !name.equals(".") && !name.equals("..") && !name.startsWith("~itm-") &&
            !name.contains("/") && !name.contains("\\") && path != null &&
            path.startsWith("/storage/") && path.endsWith("/Pictures/TagQuickShare/" + name) &&
            size != null && size.matches("[0-9]+") && row.get("_id") != null;
    }
    static boolean unchanged(Map<String, String> before, Map<String, String> current,
            String expectedIdentity, String currentIdentity, String owner) {
        return eligible(before, owner) && eligible(current, owner) && before.equals(current) &&
            expectedIdentity != null && expectedIdentity.equals(currentIdentity);
    }
    static boolean selectionAllowed(Set<Long> allowed, List<Long> selected) {
        return !selected.isEmpty() && selected.size() <= 50 &&
            new HashSet<>(selected).size() == selected.size() && allowed.containsAll(selected);
    }
}
