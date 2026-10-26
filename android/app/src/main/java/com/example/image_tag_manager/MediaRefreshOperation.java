package com.example.image_tag_manager;
import java.util.*;

/** Scans only files whose current MediaStore record is missing or inconsistent. */
final class MediaRefreshOperation {
    interface Backend {
        Set<String> indexed(List<String> paths);
        boolean scan(List<String> paths);
    }
    static boolean refresh(List<String> paths, Backend backend) {
        List<String> existing = new ArrayList<>(new LinkedHashSet<>(paths));
        if (existing.isEmpty()) return true;
        Set<String> indexed = backend.indexed(existing);
        List<String> missing = new ArrayList<>();
        for (String path : existing) if (!indexed.contains(path)) missing.add(path);
        if (missing.isEmpty()) return true;
        boolean scanned = backend.scan(missing);
        Set<String> repaired = backend.indexed(missing);
        return scanned && repaired.containsAll(missing);
    }
}
