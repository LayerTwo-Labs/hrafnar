package hugin_tests

import "core:fmt"
import "core:os"
import "core:testing"

import hugin "../../hugin"

@(test)
test_config_file_load :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hrafnar_cfg_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.aprintf("%s/hrafnar.config", dir)
	defer delete(path)

	content := `; hrafnar.config — comments in both styles
# hash comments too
[hugin]
datadir     = /data/bitcoin/blocks
index       = "/data/hrafnar index"
network     = signet
workers     = 8
bucket_bits = 13
horizon     = 50

[ignored_section]
datadir = /wrong/place
`
	testing.expect_value(t, os.write_entire_file(path, content), nil)

	fc, err := hugin.config_file_load(path)
	testing.expect_value(t, err, nil)
	defer hugin.config_file_destroy(&fc)

	testing.expect_value(t, fc.datadir, "/data/bitcoin/blocks")
	testing.expect_value(t, fc.index_dir, "/data/hrafnar index") // quoted value
	testing.expect_value(t, fc.network, "signet")
	testing.expect_value(t, fc.workers, 8)
	testing.expect_value(t, fc.bucket_bits, 13)
	testing.expect_value(t, fc.horizon, 50)
}

@(test)
test_config_file_sectionless :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hrafnar_cfg_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.aprintf("%s/hrafnar.config", dir)
	defer delete(path)

	testing.expect_value(t, os.write_entire_file(path, "datadir = /a\nindex = /b\n"), nil)
	fc, err := hugin.config_file_load(path)
	testing.expect_value(t, err, nil)
	defer hugin.config_file_destroy(&fc)
	testing.expect_value(t, fc.datadir, "/a")
	testing.expect_value(t, fc.index_dir, "/b")
	testing.expect_value(t, fc.workers, -1) // unset stays -1
}

@(test)
test_config_file_rejects_bad_input :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "hrafnar_cfg_*", context.allocator)
	testing.expect_value(t, derr, nil)
	defer {os.remove_all(dir); delete(dir)}
	path := fmt.aprintf("%s/hrafnar.config", dir)
	defer delete(path)

	// A typo'd key must fail loudly, not be silently ignored.
	testing.expect_value(t, os.write_entire_file(path, "datdir = /a\n"), nil)
	fc, err := hugin.config_file_load(path)
	hugin.config_file_destroy(&fc)
	testing.expect_value(t, err, hugin.Error(hugin.Usage_Error.Bad_Config))

	// A non-numeric numeric value must fail.
	testing.expect_value(t, os.write_entire_file(path, "workers = many\n"), nil)
	fc2, err2 := hugin.config_file_load(path)
	hugin.config_file_destroy(&fc2)
	testing.expect_value(t, err2, hugin.Error(hugin.Usage_Error.Bad_Config))

	// Missing file surfaces as an os error.
	_, err3 := hugin.config_file_load(fmt.tprintf("%s/nope.config", dir))
	testing.expect(t, err3 != nil, "missing file must error")
}
