# typed: true
# frozen_string_literal: true

class IntegrationTest < Minitest::Test
  TEST_FILE_FIXTURES = File.expand_path("../../fixtures/", __FILE__)

  class WorkerResult < T::Struct
    const :worker_id, String
    const :status, Process::Status
    const :stdout, String
  end

  def spawn_worker(
    test_file:,
    run_id: SecureRandom.uuid,
    worker_id: SecureRandom.uuid,
    arguments: {},
    timeout: 10,
    env: {}
  )
    Thread.new do
      Thread.current.report_on_exception = false

      stdout_reader, stdout_writer = IO.pipe
      stdout_thread = Thread.new { stdout_reader.read }

      status = nil
      begin
        pid = T.unsafe(Process).spawn(
          env,
          RbConfig.ruby,
          File.join(TEST_FILE_FIXTURES, test_file),
          "--verbose",
          "--run-id",
          run_id,
          "--worker-id",
          worker_id,
          "--enable-distributed",
          *arguments.flat_map(&:itself),
          out: stdout_writer,
        )

        killer = Thread.new do
          sleep(timeout)
          Process.kill("KILL", pid)
          $stderr.puts("Sent kill signal to worker #{worker_id} after #{timeout}s...")
        rescue Errno::ESRCH
          # spawned process exited normally
        end

        begin
          _, status = Process.waitpid2(pid)
        ensure
          killer.kill
        end
      ensure
        stdout_writer.close
      end

      WorkerResult.new(
        worker_id: worker_id,
        status: T.must(status),
        stdout: T.cast(stdout_thread.value, String),
      )
    end
  end

  def boxed_workers_output(workers)
    workers.map { |worker| output_box(worker_header(worker), worker.stdout) }.join("\n")
  end

  def workers_output(workers)
    workers.map(&:stdout).join("\n")
  end

  def normalize_output(output)
    # Changes the location of an assertion to always be the same
    output.gsub(%r{\[[\w\.\-\/]+:\d+\]}, "[/path/to/file.rb:123]")
  end

  def output_box(header, content)
    <<~BOX
      ┌─── #{header} ───────────────────────────────────
      │ #{content.gsub("\n", "\n│ ")}
      └────────────────────────────────────────#{"─" * header.length}
    BOX
  end

  def assert_output_includes(worker, output)
    if worker.stdout.include?(output)
      pass
    else
      flunk(<<~EOM)
        Expected the output of the worker to include #{output.inspect}.
        #{output_box("STDOUT", worker.stdout)}
      EOM
    end
  end

  def worker_header(worker)
    result = if (exitstatus = worker.status.exitstatus)
      "exited with #{exitstatus}"
    elsif (termsig = worker.status.termsig)
      "signaled with #{Signal.signame(termsig)}"
    else
      raise "Unexpected process status: #{worker.status.inspect}"
    end
    "Worker #{worker.worker_id} (#{result})"
  end

  def refute_worker_successful(worker)
    if worker.status.exitstatus == 1
      pass
    else
      flunk(<<~EOM)
        The worker #{worker.worker_id} was unexpectedly successful.
        #{output_box(worker_header(worker), worker.stdout)}
      EOM
    end
  end

  def assert_worker_successful(worker)
    if worker.status.exitstatus == 0
      pass
    else
      flunk(<<~EOM)
        The worker #{worker.worker_id} unexpectedly was not successful
        #{output_box(worker_header(worker), worker.stdout)}
      EOM
    end
  end

  def assert_all_workers_failed(workers)
    if workers.all? { |worker| worker.status.exitstatus == 1 }
      pass
    else
      worker_boxes = workers.map { |worker| output_box(worker_header(worker), worker.stdout) }
      flunk("Not all workers failed with exit status 1.\n\n#{worker_boxes.join("\n")}")
    end
  end

  def assert_some_workers_failed(workers)
    if workers.any? { |worker| worker.status.exitstatus == 1 }
      pass
    else
      worker_boxes = workers.map { |worker| output_box(worker_header(worker), worker.stdout) }
      flunk("At least one should have failed with exit status 1.\n\n#{worker_boxes.join("\n")}")
    end
  end

  def assert_all_workers_successful(workers)
    if workers.all? { |worker| worker.status.exitstatus == 0 }
      pass
    else
      worker_boxes = workers.map { |worker| output_box(worker_header(worker), worker.stdout) }
      flunk("Not all workers were successful.\n\n#{worker_boxes.join("\n")}")
    end
  end
end
