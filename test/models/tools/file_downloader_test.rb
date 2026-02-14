require "test_helper"

class Tools::FileDownloaderTest < ActiveSupport::TestCase
  setup do
    as_workspace(:default)
    @downloader = Tools::FileDownloader.new(agent_id: 1, conversation_id: 1)
  end

  teardown do
    FileUtils.rm_rf(Rails.root.join("data", "downloads", "1"))
  end

  test "rejects non-http schemes" do
    result = @downloader.call("ftp://example.com/file.txt")
    assert_equal false, result.success
    assert_match(/Only http\/https/, result.error)
  end

  test "rejects invalid URLs" do
    result = @downloader.call("not a url at all ://")
    assert_equal false, result.success
    assert_match(/Invalid URL|Only http/, result.error)
  end

  test "blocks private IP ranges" do
    Resolv.stubs(:getaddresses).returns(["192.168.1.1"])
    result = @downloader.call("http://internal.example.com/file.txt")
    assert_equal false, result.success
    assert_match(/private\/internal/, result.error)
  end

  test "blocks localhost" do
    Resolv.stubs(:getaddresses).returns(["127.0.0.1"])
    result = @downloader.call("http://localhost/file.txt")
    assert_equal false, result.success
    assert_match(/private\/internal/, result.error)
  end

  test "blocks 10.x.x.x range" do
    Resolv.stubs(:getaddresses).returns(["10.0.0.5"])
    result = @downloader.call("http://internal.corp/data.csv")
    assert_equal false, result.success
    assert_match(/private\/internal/, result.error)
  end

  test "blocks 172.16.x.x range" do
    Resolv.stubs(:getaddresses).returns(["172.16.0.1"])
    result = @downloader.call("http://docker.local/file.txt")
    assert_equal false, result.success
    assert_match(/private\/internal/, result.error)
  end

  test "blocks link-local addresses" do
    Resolv.stubs(:getaddresses).returns(["169.254.1.1"])
    result = @downloader.call("http://metadata.example.com/")
    assert_equal false, result.success
    assert_match(/private\/internal/, result.error)
  end

  test "blocks IPv6 loopback" do
    Resolv.stubs(:getaddresses).returns(["::1"])
    result = @downloader.call("http://localhost6/file.txt")
    assert_equal false, result.success
    assert_match(/private\/internal/, result.error)
  end

  test "rejects files exceeding max size" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    big_body = "x" * (Tools::FileDownloader::MAX_FILE_SIZE + 1)
    response = stub(status: 200, body: stub(to_s: big_body))
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/huge.bin")
    assert_equal false, result.success
    assert_match(/too large/, result.error)
  end

  test "handles HTTP error status" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    response = stub(status: 404)
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/missing.txt")
    assert_equal false, result.success
    assert_equal "HTTP 404", result.error
  end

  test "successful download saves file" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    response = stub(status: 200, body: stub(to_s: "file content here"))
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/report.pdf")
    assert_equal true, result.success
    assert_equal 17, result.size
    assert File.exist?(result.path)
    assert_equal "file content here", File.read(result.path)
    assert_match %r{data/downloads/1/1/report\.pdf$}, result.path
  end

  test "successful download with custom filename" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    response = stub(status: 200, body: stub(to_s: "data"))
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/download?id=123", filename: "my-report.csv")
    assert_equal true, result.success
    assert_match(/my-report\.csv$/, result.path)
  end

  test "sanitizes dangerous filename characters" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    response = stub(status: 200, body: stub(to_s: "data"))
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/file.txt", filename: "../../../etc/passwd")
    assert_equal true, result.success
    assert_no_match %r{\.\.}, result.path
    assert_match %r{data/downloads/1/1/}, result.path
  end

  test "sanitizes dotfiles" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    response = stub(status: 200, body: stub(to_s: "data"))
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/.env")
    assert_equal true, result.success
    refute File.basename(result.path).start_with?(".")
  end

  test "handles empty URL path gracefully" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    response = stub(status: 200, body: stub(to_s: "data"))
    HTTPX.stubs(:get).returns(response)

    result = @downloader.call("https://example.com/")
    assert_equal true, result.success
    assert_match(/download$/, result.path)
  end

  test "handles network errors" do
    Resolv.stubs(:getaddresses).returns(["93.184.216.34"])
    HTTPX.stubs(:get).raises(StandardError, "Connection refused")

    result = @downloader.call("https://example.com/file.txt")
    assert_equal false, result.success
    assert_match(/Connection refused/, result.error)
  end

  test "handles unresolvable hostname" do
    Resolv.stubs(:getaddresses).returns([])

    result = @downloader.call("https://nonexistent.invalid/file.txt")
    assert_equal false, result.success
    assert_match(/Could not resolve/, result.error)
  end
end
