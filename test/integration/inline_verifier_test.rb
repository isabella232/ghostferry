require "test_helper"

class InlineVerifierTest < GhostferryTestCase
  INSERT_TRIGGER_NAME = "corrupting_insert_trigger"
  ASCIIDATA = "foobar"
  UTF8MB3DATA = "これは普通なストリングです"
  UTF8MB4DATA = "𠜎𠜱𠝹𠱓𠱸𠲖𠳏𠳕𠴕𠵼𠵿𠸎𠸏𠹷"
  CHARSET_TO_COLLATION = {
    "utf8mb4" => "utf8mb4_unicode_ci",
    "utf8mb3" => "utf8_unicode_ci",
  }

  def teardown
    drop_triggers
  end

  #############################
  # General Integration Tests #
  #############################

  def test_corrupted_insert_is_detected_inline_with_batch_writer
    seed_random_data(source_db, number_of_rows: 3)
    seed_random_data(target_db, number_of_rows: 0)

    result = source_db.query("SELECT id FROM #{DEFAULT_FULL_TABLE_NAME} ORDER BY RAND() LIMIT 1")
    corrupting_id = result.first["id"]

    enable_corrupting_insert_trigger(corrupting_id)

    ghostferry = new_ghostferry(MINIMAL_GHOSTFERRY, config: { verifier_type: "Inline" })
    ghostferry.run_expecting_interrupt

    refute_nil ghostferry.error
    err_msg = ghostferry.error["ErrMessage"]
    assert err_msg.include?("row fingerprints for pks [#{corrupting_id}] on #{DEFAULT_DB}.#{DEFAULT_TABLE} do not match"), message: err_msg

    # Make sure it is not inserted into the target
    results = target_db.query("SELECT * FROM #{DEFAULT_FULL_TABLE_NAME} WHERE id = #{corrupting_id}")
    assert_equal 0, results.count
  end

  def test_different_compressed_data_is_detected_inline_with_batch_writer
    [source_db, target_db].each do |db|
      db.query("CREATE DATABASE IF NOT EXISTS #{DEFAULT_DB}")
      db.query("CREATE TABLE IF NOT EXISTS #{DEFAULT_FULL_TABLE_NAME} (id bigint(20) not null auto_increment, data BLOB, primary key(id))")
    end

    compressed_data1 = "\x08" + "\x0cabcd" + "\x01\x02" # abcdcdcd
    compressed_data2 = "\x08" + "\x0cabcd" + "\x01\x01" # abcddddd

    source_db.query("INSERT INTO #{DEFAULT_FULL_TABLE_NAME} (id, data) VALUES (1, _binary'#{compressed_data1}')")
    target_db.query("INSERT INTO #{DEFAULT_FULL_TABLE_NAME} (id, data) VALUES (1, _binary'#{compressed_data2}')")

    ghostferry = new_ghostferry(MINIMAL_GHOSTFERRY, config: { verifier_type: "Inline", compressed_data: true })
    ghostferry.run_expecting_interrupt

    refute_nil ghostferry.error
    err_msg = ghostferry.error["ErrMessage"]
    assert err_msg.include?("row fingerprints for pks [1] on #{DEFAULT_DB}.#{DEFAULT_TABLE} do not match"), message: err_msg
  end

  def test_same_decompressed_data_different_compressed_test_passes_inline_verification
    [source_db, target_db].each do |db|
      db.query("CREATE DATABASE IF NOT EXISTS #{DEFAULT_DB}")
      db.query("CREATE TABLE IF NOT EXISTS #{DEFAULT_FULL_TABLE_NAME} (id bigint(20) not null auto_increment, data BLOB, primary key(id))")
    end

    compressed_data1 = load_fixture("urls1.snappy")
    compressed_data2 = load_fixture("urls2.snappy")

    source_db.prepare("INSERT INTO #{DEFAULT_FULL_TABLE_NAME} (id, data) VALUES (?, ?)").execute(1, compressed_data1)
    target_db.prepare("INSERT INTO #{DEFAULT_FULL_TABLE_NAME} (id, data) VALUES (?, ?)").execute(1, compressed_data2)

    ghostferry = new_ghostferry(MINIMAL_GHOSTFERRY, config: { verifier_type: "Inline", compressed_data: true })
    ghostferry.run

    assert_nil ghostferry.error
  end

  def test_catches_binlog_streamer_corruption
    seed_random_data(source_db, number_of_rows: 1)
    seed_random_data(target_db, number_of_rows: 0)

    result = source_db.query("SELECT id FROM #{DEFAULT_FULL_TABLE_NAME} LIMIT 1")
    corrupting_id = result.first["id"] + 1
    enable_corrupting_insert_trigger(corrupting_id)

    ghostferry = new_ghostferry(MINIMAL_GHOSTFERRY, config: { verifier_type: "Inline" })

    ghostferry.on_status(Ghostferry::Status::ROW_COPY_COMPLETED) do
      source_db.query("INSERT INTO #{DEFAULT_FULL_TABLE_NAME} (id, data) VALUES (#{corrupting_id}, 'data')")
    end

    verification_ran = false
    ghostferry.on_status(Ghostferry::Status::VERIFIED) do |*incorrect_tables|
      verification_ran = true
      assert_equal ["gftest.test_table_1"], incorrect_tables
    end

    ghostferry.run
    assert verification_ran
    assert_equal "cutover verification failed for: gftest.test_table_1 [pks: #{corrupting_id} ] ", ghostferry.error_lines.last["msg"]
  end

  ###################
  # Collation Tests #
  ###################

  def test_ascii_data_from_utfmb3_to_utfmb4
    run_collation_test(ASCIIDATA, "utf8mb3", "utf8mb4", identical: true)
  end

  def test_ascii_data_from_utfmb4_to_utfmb3
    run_collation_test(ASCIIDATA, "utf8mb4", "utf8mb3", identical: true)
  end

  def test_utfmb3_data_from_utfmb3_to_utfmb4
    run_collation_test(UTF8MB3DATA, "utf8mb3", "utf8mb4", identical: true)
  end

  def test_utfmb3_data_from_utfmb4_to_utfmb3
    run_collation_test(UTF8MB3DATA, "utf8mb4", "utf8mb3", identical: true)
  end

  def test_utfmb4_data_from_utfmb4_to_utfmb3
    run_collation_test(UTF8MB4DATA, "utf8mb4", "utf8mb3", identical: false)
  end

  private

  def run_collation_test(data, source_charset, target_charset, identical:)
    seed_random_data(source_db, number_of_rows: 0)
    seed_random_data(target_db, number_of_rows: 0)

    unsafe_source_db_config = source_db_config
    unsafe_source_db_config[:init_command] = "SET @@SESSION.sql_mode = ''"
    unsafe_source_db = Mysql2::Client.new(unsafe_source_db_config)

    unsafe_target_db_config = target_db_config
    unsafe_target_db_config[:init_command] = "SET @@SESSION.sql_mode = ''"
    unsafe_target_db = Mysql2::Client.new(unsafe_target_db_config)

    set_data_column_collation(unsafe_source_db, source_charset)
    set_data_column_collation(unsafe_target_db, target_charset)

    unsafe_source_db.query("INSERT INTO #{DEFAULT_FULL_TABLE_NAME} (id, data) VALUES (1, '#{data}')")

    verify_during_cutover_ran = false
    incorrect_tables = nil
    ghostferry = new_ghostferry(MINIMAL_GHOSTFERRY, config: { verifier_type: "Inline" })
    ghostferry.on_status(Ghostferry::Status::VERIFIED) do |*t|
      verify_during_cutover_ran = true
      incorrect_tables = t
    end

    if identical
      ghostferry.run
      assert verify_during_cutover_ran
      assert_equal [], incorrect_tables

      rows = unsafe_target_db.query("SELECT * FROM #{DEFAULT_FULL_TABLE_NAME} WHERE id = 1")
      assert_equal 1, rows.count
      rows.each do |row|
        assert_equal data, row["data"]
      end
    else
      ghostferry.run_expecting_interrupt

      refute_nil ghostferry.error
      err_msg = ghostferry.error["ErrMessage"]
      assert err_msg.include?("row fingerprints for pks [1] on #{DEFAULT_DB}.#{DEFAULT_TABLE} do not match"), message: err_msg
    end
  end

  def set_data_column_collation(db, charset)
    db.query("ALTER TABLE #{DEFAULT_FULL_TABLE_NAME} MODIFY data VARCHAR(255) CHARACTER SET #{charset} COLLATE #{CHARSET_TO_COLLATION[charset]}")
  end

  def enable_corrupting_insert_trigger(corrupting_id)
    query = [
      "CREATE TRIGGER #{INSERT_TRIGGER_NAME} BEFORE INSERT ON #{DEFAULT_TABLE}",
      "FOR EACH ROW BEGIN",
      "IF NEW.id = #{corrupting_id} THEN",
      "SET NEW.data = 'corrupted';",
      "END IF;",
      "END",
    ].join("\n")

    target_db_conn_with_db_selected.query(query)
  end

  def drop_triggers
    target_db_conn_with_db_selected.query("DROP TRIGGER IF EXISTS #{INSERT_TRIGGER_NAME}")
  end

  def target_db_conn_with_db_selected
    @target_db_conn_with_db_selected ||= begin
      conf = target_db_config
      conf[:database] = DEFAULT_DB
      Mysql2::Client.new(conf)
    end
  end
end
