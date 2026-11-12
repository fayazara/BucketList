package main

import (
	"encoding/xml"
	"os"
	"strings"
	"testing"
)

func TestParseSparkleSignature(t *testing.T) {
	output := `<enclosure sparkle:edSignature="abc123==" length="456789" />`

	signature, length := parseSparkleSignature(output)

	if signature != "abc123==" {
		t.Fatalf("signature = %q, want %q", signature, "abc123==")
	}
	if length != "456789" {
		t.Fatalf("length = %q, want %q", length, "456789")
	}
}

func TestWriteAppcast(t *testing.T) {
	path := t.TempDir() + "/appcast.xml"
	items := []Item{
		{
			Title:              "Version 1.0",
			Version:            "1",
			ShortVersionString: "1.0",
			MinSystemVersion:   minSystemVer,
			PubDate:            "Tue, 12 May 2026 09:30:00 +0000",
			Description:        buildDescription("1.0", []string{"Initial release"}),
			Enclosure: Enclosure{
				URL:         "https://github.com/fayazara/BucketList/releases/download/v1.0/BucketList.dmg",
				Type:        "application/octet-stream",
				EdSignature: "sig==",
				Length:      "123",
			},
		},
	}

	if err := writeAppcast(path, items); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	text := string(data)
	if !strings.Contains(text, "<title>Bucket List Updates</title>") {
		t.Fatal("appcast title was not written")
	}
	if !strings.Contains(text, "Run: go run ./cmd/bucketlist-release") {
		t.Fatal("release instructions were not written")
	}

	var appcast Appcast
	if err := xml.Unmarshal(data, &appcast); err != nil {
		t.Fatal(err)
	}
	if got := len(appcast.Channel.Items); got != 1 {
		t.Fatalf("item count = %d, want 1", got)
	}
	if appcast.Channel.Items[0].Version != "1" {
		t.Fatalf("version = %q, want 1", appcast.Channel.Items[0].Version)
	}
}

func TestBumpVersion(t *testing.T) {
	dir := t.TempDir()
	original := `{
  "targets": [
    {
      "build-settings": {
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "0.0.1",
      },
    },
  ],
}
`
	if err := os.WriteFile(dir+"/"+projectFile, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := bumpVersion(dir, "0.1.0", "7"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(dir + "/" + projectFile)
	text := string(data)
	if !strings.Contains(text, `"MARKETING_VERSION": "0.1.0",`) {
		t.Fatalf("MARKETING_VERSION not bumped:\n%s", text)
	}
	if !strings.Contains(text, `"CURRENT_PROJECT_VERSION": "7",`) {
		t.Fatalf("CURRENT_PROJECT_VERSION not bumped:\n%s", text)
	}
}
