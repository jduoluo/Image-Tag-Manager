package com.example.image_tag_manager;

import java.util.*;

/** Host tests for the production MediaStore operation; no Android device or user files. */
public final class MediaStoreRenameOperationTest {
    static final String SOURCE = "/storage/emulated/0/Pictures/精灵😀.png";
    static final String TARGET = "/storage/emulated/0/Pictures/~itm-test.png";
    static class Fake implements MediaStoreRenameOperation.Backend {
        Map<String, String> files = new HashMap<>();
        MediaStoreRenameOperation.Row row = new MediaStoreRenameOperation.Row("content://test/42", SOURCE, "精灵😀.png");
        int calls;
        int mode;
        Fake() { files.put(SOURCE, "id"); }
        public MediaStoreRenameOperation.Row rowForPath(String path) { return row; }
        public MediaStoreRenameOperation.Row rowForUri(String uri) { return row; }
        public String identityOrNull(String path) { return files.get(path); }
        public List<String> directoryNames(String source) {
            List<String> names = new ArrayList<>();
            for (String path : files.keySet()) names.add(path.substring(path.lastIndexOf('/') + 1));
            return names;
        }
        public int update(MediaStoreRenameOperation.Row before, String name) {
            calls++;
            if (mode == 1) throw new SecurityException("permission denied");
            if (mode == 4) return 0;
            String requested = before.path.substring(0, before.path.lastIndexOf('/') + 1) + name;
            String path = mode == 2 ? requested + ".auto" : mode == 6 ? requested.toUpperCase(Locale.ROOT) : requested;
            files.put(path, files.remove(before.path));
            row = new MediaStoreRenameOperation.Row(before.uri, path, path.substring(path.lastIndexOf('/') + 1));
            if (mode == 3) throw new IllegalStateException("after write");
            if (mode == 5) files.put(path, "replacement");
            return 1;
        }
    }
    interface Checked { void run(); }
    static RuntimeException rejected(Checked run) {
        try { run.run(); } catch (RuntimeException error) { return error; }
        throw new AssertionError("Unexpected success");
    }
    static void check(boolean accepted) { if (!accepted) throw new AssertionError(); }
    static void execute(Fake fake) { MediaStoreRenameOperation.rename(fake, SOURCE, TARGET, "id"); }
    public static void main(String[] args) {
        Fake normal = new Fake(); execute(normal);
        check(normal.calls == 1 && "id".equals(normal.files.get(TARGET)) && !normal.files.containsKey(SOURCE));
        Fake conflict = new Fake(); conflict.files.put(TARGET.toUpperCase(Locale.ROOT), "other");
        rejected(() -> execute(conflict)); check(conflict.calls == 0 && conflict.files.size() == 2);
        Fake changed = new Fake(); changed.files.put(SOURCE, "changed");
        rejected(() -> execute(changed)); check(changed.calls == 0);
        Fake denied = new Fake(); denied.mode = 1;
        check(!(rejected(() -> execute(denied)) instanceof MediaStoreRenameOperation.UncertainResultException));
        check(denied.calls == 1 && denied.files.containsKey(SOURCE));
        Fake automatic = new Fake(); automatic.mode = 2;
        RuntimeException automaticError = rejected(() -> execute(automatic));
        check(automaticError instanceof MediaStoreRenameOperation.UncertainResultException);
        check(automaticError.getMessage().contains(TARGET + ".auto") && automatic.calls == 1);
        Fake afterWrite = new Fake(); afterWrite.mode = 3; execute(afterWrite); check(afterWrite.calls == 1);
        Fake zero = new Fake(); zero.mode = 4; rejected(() -> execute(zero)); check(zero.calls == 1 && zero.files.containsKey(SOURCE));
        Fake replaced = new Fake(); replaced.mode = 5;
        check(rejected(() -> execute(replaced)) instanceof MediaStoreRenameOperation.UncertainResultException);
        Fake cycle = new Fake(); execute(cycle);
        String finalPath = "/storage/emulated/0/Pictures/[测试]精灵😀.png";
        MediaStoreRenameOperation.rename(cycle, TARGET, finalPath, "id");
        MediaStoreRenameOperation.rename(cycle, finalPath, TARGET, "id");
        MediaStoreRenameOperation.rename(cycle, TARGET, SOURCE, "id");
        check(cycle.calls == 4 && "id".equals(cycle.files.get(SOURCE)) && cycle.files.size() == 1);
        // A provider may retain a different spelling of the same physical parent.
        Fake alias = new Fake() {
            @Override public MediaStoreRenameOperation.Row rowForPath(String path) {
                return rowForUri("content://image/1");
            }
            @Override public MediaStoreRenameOperation.Row rowForUri(String uri) {
                return new MediaStoreRenameOperation.Row(row.uri,
                    row.path.replace("/Pictures/", "/pictures/"), row.name);
            }
            @Override public boolean samePath(String first, String second) {
                return first.replace("/Pictures/", "/pictures/").equals(second);
            }
            @Override public int update(MediaStoreRenameOperation.Row before, String name) {
                return super.update(row, name);
            }
        };
        execute(alias);
        check(alias.calls == 1 && "id".equals(alias.files.get(TARGET)));
        Fake wrongDirectory = new Fake() {
            @Override public MediaStoreRenameOperation.Row rowForPath(String path) {
                return new MediaStoreRenameOperation.Row(row.uri, row.path.replace("/Pictures/", "/pictures/"), row.name);
            }
        };
        rejected(() -> execute(wrongDirectory));
        check(wrongDirectory.calls == 0);
        class SourceCase extends Fake {
            final String actual = SOURCE.replace(".png", ".PNG");
            SourceCase() { files.clear(); files.put(actual, "id"); }
            @Override public String identityOrNull(String path) {
                for (String key : files.keySet()) if (key.equalsIgnoreCase(path)) return files.get(key);
                return null;
            }
            @Override public boolean matchesSource(String source, MediaStoreRenameOperation.Row before) {
                return source.equalsIgnoreCase(before.path) &&
                    source.substring(source.lastIndexOf('/') + 1).equalsIgnoreCase(before.name) &&
                    Objects.equals(identityOrNull(source), identityOrNull(before.path));
            }
            @Override public int update(MediaStoreRenameOperation.Row before, String name) {
                return super.update(new MediaStoreRenameOperation.Row(before.uri, actual, before.name), name);
            }
        }
        SourceCase sourceCase = new SourceCase();
        MediaStoreRenameOperation.rename(sourceCase, sourceCase.actual, TARGET, "id");
        check(sourceCase.calls == 1 && "id".equals(sourceCase.files.get(TARGET)));
        SourceCase targetCase = new SourceCase(); targetCase.mode = 6;
        check(rejected(() -> MediaStoreRenameOperation.rename(targetCase, targetCase.actual, TARGET, "id"))
            instanceof MediaStoreRenameOperation.UncertainResultException);
        System.out.println("13 MediaStore rename policy scenarios passed (host fake backend).");
    }
}
