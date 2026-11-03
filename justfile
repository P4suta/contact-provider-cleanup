set shell := ["bash", "-euo", "pipefail", "-c"]

bundle := `rg --only-matching --replace '$1' '^CLEANUP_BUNDLE_ID = (.+)$' Config/Identity.xcconfig`

# The Public Phonebook snapshot whose telephone numbers the QA build provided.
snapshot := "5bd74f209c80bf850edeced4031076ba3924713f6f7f5f3209503276bccc3814"
csv_sha256 := "ee97353f6ed1532c9474c4dbaeab06dd3087b6e377cdccdf8b174b5581b398a1"

default:
    @just --list

# Write the provider item identifiers of the Public Phonebook snapshot.
identifiers:
    mkdir -p build
    xh --download --output build/contacts.csv.gz GET "https://www.dial.page/api/datasets/{{ snapshot }}/{{ csv_sha256 }}/contacts.csv.gz"
    echo "{{ csv_sha256 }}  build/contacts.csv.gz" | shasum --algorithm 256 --check
    duckdb -c "COPY (SELECT DISTINCT 'phone:+' || regexp_replace(n, '[^0-9]', '', 'g') AS id FROM (SELECT unnest(string_split(phone_numbers, ';')) AS n FROM read_csv('build/contacts.csv.gz', all_varchar = true)) WHERE regexp_replace(n, '[^0-9]', '', 'g') <> '' ORDER BY id) TO 'Provider/identifiers.txt' (HEADER false, QUOTE '')"

# Build the app and its extension for any iPhone without signing.
build:
    xcodegen generate
    xcodebuild -project ContactProviderCleanup.xcodeproj -scheme ContactProviderCleanup -configuration Debug -destination generic/platform=iOS -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Build, install, and start the batched deletion on a connected iPhone.
run device:
    xcodegen generate
    xcodebuild -project ContactProviderCleanup.xcodeproj -scheme ContactProviderCleanup -configuration Debug -destination "id={{ device }}" -derivedDataPath build -allowProvisioningUpdates build
    xcrun devicectl device install app --device "{{ device }}" build/Build/Products/Debug-iphoneos/ContactProviderCleanup.app
    xcrun devicectl device process launch --terminate-existing --device "{{ device }}" "{{ bundle }}" --signal

# Copy the shared progress log from the iPhone into build/cleanup.log.
log device:
    xcrun devicectl device copy from --device "{{ device }}" --domain-type appGroupDataContainer --domain-identifier "group.{{ bundle }}" --source Library/Caches/cleanup.log --destination build/cleanup.log
