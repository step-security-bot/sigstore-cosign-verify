# frozen_string_literal: true

# Copyright 2024 The Sigstore Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative "root"
require_relative "../internal/json"

module Sigstore::TUF
  class ExpiredMetadataError < StandardError; end
  class EqualVersionNumberError < StandardError; end

  class TrustedMetadataSet
    def initialize(root_data, envelope_type, reference_time: Time.now.utc)
      @trusted_set = {}
      @reference_time = reference_time
      @envelope_type = envelope_type

      # debug
      load_trusted_root(root_data)
    end

    def root
      @trusted_set.fetch("root")
    end

    def root=(data)
      raise "cannot update root after timestamp" if @trusted_set.key?("timestamp")

      metadata, signed, signatures = load_data(Root, data, root)
      metadata.verify_delegate("root", Sigstore::Internal::JSON.canonical_generate(signed), signatures)
      raise "root version incr" if metadata.version != root.version + 1

      @trusted_set["root"] = metadata

      # debug
    end

    def snapshot
      @trusted_set.fetch("snapshot")
    end

    def timestamp
      @trusted_set.fetch("timestamp")
    end

    def timestamp=(data)
      raise "cannot update timestamp after snapshot" if @trusted_set.key?("snapshot")

      if root.expired?(@reference_time)
        raise ExpiredMetadataError,
              "final root.json expired at #{root.expires}, is #{@reference_time}"
      end

      metadata, = load_data(Timestamp, data, root)

      if include?(Timestamp::TYPE)
        raise "timestamp version did not increase" if metadata.version < timestamp.version
        raise EqualVersionNumberError if metadata.version == timestamp.version

        snapshot_meta = timestamp.snapshot_meta
        new_snapshot_meta = metadata.snapshot_meta
        raise "snapshot version did not increase" if new_snapshot_meta.version < snapshot_meta.version
      end

      @trusted_set["timestamp"] = metadata
      check_final_timestamp
    end

    def snapshot=(data, trusted: false)
      raise "cannot update snapshot before timestamp" unless @trusted_set.key?("timestamp")
      raise "cannot update snapshot after targets" if @trusted_set.key?("targets")

      check_final_timestamp

      snapshot_meta = timestamp.snapshot_meta

      snapshot_meta.verify_length_and_hashes(data) unless trusted

      new_snapshot, = load_data(Snapshot, data, root)

      raise "snapshot version incr" if include?(Snapshot::TYPE) && (new_snapshot.version < snapshot.version)

      @trusted_set["snapshot"] = new_snapshot
      # debug "Updated snapshot v#{new_snapshot.version}"
      check_final_snapshot
    end

    def include?(type)
      @trusted_set.key?(type)
    end

    def [](role)
      @trusted_set.fetch(role)
    end

    def update_delegated_targets(data, role, parent_role)
      raise "cannot update targets before snapshot" unless @trusted_set.key?("snapshot")

      check_final_snapshot

      delegator = @trusted_set.fetch(parent_role)
      raise "cannot load targets before delegator" unless delegator

      # debug "Updating #{role} delegated by #{parent_role}"

      meta = snapshot.meta.fetch("#{role}.json")
      raise "No metadata for role: #{role}" unless meta

      meta.verify_length_and_hashes(data)

      new_delegate, = load_data(Targets, data, delegator, role)
      version = new_delegate.version
      raise "delegated targets version incr" if version != meta.version

      raise "expired delegated targets" if new_delegate.expired?(@reference_time)

      @trusted_set[role] = new_delegate
      # debug "Updated #{role} v#{version}"
      new_delegate
    end

    private

    def load_trusted_root(data)
      root, signed, signatures = load_data(Root, data, nil)
      # verify the new root is signed by itself
      root.verify_delegate("root", Sigstore::Internal::JSON.canonical_generate(signed), signatures)

      @trusted_set["root"] = root
    end

    def load_data(type, data, delegator, role_name = nil)
      metadata = JSON.parse(data)
      signed = metadata.fetch("signed")
      unless signed.fetch("_type") == type::TYPE
        raise "Expected type to be #{type::TYPE}, got #{signed.fetch("_type").inspect}"
      end

      signatures = metadata.fetch("signatures")
      metadata = type.new(signed)
      delegator&.verify_delegate(role_name || type::TYPE,
                                 Sigstore::Internal::JSON.canonical_generate(signed), signatures)
      [metadata, signed, signatures]
    end

    def check_final_timestamp
      return unless timestamp.expired?(@reference_time)

      raise ExpiredMetadataError,
            "final timestamp.json is expired (expired at #{timestamp.expires} vs reference time #{@reference_time})"
    end

    def check_final_snapshot
      raise ExpiredMetadataError, "final snapshot.json is expired" if snapshot.expired?(@reference_time)

      snapshot_meta = timestamp.snapshot_meta
      return unless snapshot.version != snapshot_meta.version

      raise "snapshot version mismatch " \
            "(snapshot #{snapshot.version} != timestamp snapshot meta #{snapshot_meta.version})"
    end
  end
end
