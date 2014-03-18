// 
// Copyright 2011-2012 Jeff Bush
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// 

`include "defines.v"

//
// - Queues up L1 cache read misses and issues requests to the L2 cache.
// - Tracks pending requests and matches responses from L2 cache.
// - Handles case where multiple strands miss on the same line, making sure only
//   one request goes to the cache.
// - Sends wakeup signals to restart strands who's loads have been satisfied.
//

module l1_load_miss_queue
	#(parameter unit_id_t UNIT_ID = 2'd0,
	parameter unit_id_t CORE_ID = 0)

	(input                                 clk,
	input                                  reset,

	// To/From L1 cache
	input                                  request_i,
	input                                  synchronized_i,
	input [25:0]                           request_addr,
	input [1:0]                            victim_way_i,
	input [`STRAND_INDEX_WIDTH - 1:0]      strand_i,
	output [`STRANDS_PER_CORE - 1:0]       load_complete_strands_o,
	
	// To L2 cache
	input                                  l2req_ready,
	output l2req_packet_t                  l2req_packet,
	input l2rsp_packet_t                   l2rsp_packet,
	input                                  is_for_me);

	typedef struct packed {
		logic[`STRANDS_PER_CORE - 1:0] waiting_strands; // one bit per strand
		logic[25:0] address;
		logic[1:0] way;
		logic enqueued;
		logic acknowledged;
		logic synchronized;
	} entries_t;

	entries_t entries[0:`STRANDS_PER_CORE - 1];
	logic load_already_pending;
	logic[`STRAND_INDEX_WIDTH - 1:0] load_already_pending_entry;
	logic[`STRAND_INDEX_WIDTH - 1:0] issue_idx;
	logic[`STRANDS_PER_CORE - 1:0] issue_oh;

	assign l2req_packet.op = entries[issue_idx].synchronized ? L2REQ_LOAD_SYNC : L2REQ_LOAD;	
	assign l2req_packet.way = entries[issue_idx].way;
	assign l2req_packet.address = entries[issue_idx].address;
	assign l2req_packet.unit = UNIT_ID;
	assign l2req_packet.strand = issue_idx;
	assign l2req_packet.data = 0;
	assign l2req_packet.mask = 0;
	assign l2req_packet.core = CORE_ID;

	//
	// This is a bit subtle.
	// There can be multiple hits in the load CAM for the same cache line,
	// because synchronized loads always allocate a new entry (although they use
	// the same way as the existing entry to ensure data is not duplicated in the
	// L1 cache). 
	// When there are multiple synchronized loads for the same line (common 
	// when there is contention for a spinlock), we ignore the load_already_pending
	// signal. However, in the case where a non-synchronized load misses on the 
	// same cache line that a synchronized load is pending on, we want to piggyback 
	// on one of the pending requests. Use a basic priority encoder to find the 
	// lowest one (I don't think it really matters which; they all have the same way
	// encoded).
	//
	logic[`STRANDS_PER_CORE - 1:0] load_cam_hit;
	genvar cam_entry;
	generate
		for (cam_entry = 0; cam_entry < `STRANDS_PER_CORE; cam_entry = cam_entry + 1)
		begin : lookup
			assign load_cam_hit[cam_entry] = entries[cam_entry].enqueued	
				&& entries[cam_entry].address == request_addr;
		end
	endgenerate

	// Find lowest set bit in hit array
	wire[`STRANDS_PER_CORE - 1:0] load_already_pending_oh = load_cam_hit 
		& ~(load_cam_hit - 1);

	assign load_already_pending = |load_already_pending_oh;
	one_hot_to_index #(.NUM_SIGNALS(`STRANDS_PER_CORE)) cvt_cam_lookup(
		.one_hot(load_already_pending_oh),
		.index(load_already_pending_entry));

	logic[`STRANDS_PER_CORE - 1:0] issue_request;

	genvar queue_idx;
	generate
		for (queue_idx = 0; queue_idx < `STRANDS_PER_CORE; queue_idx = queue_idx + 1)
		begin : update_request
			assign issue_request[queue_idx] = entries[queue_idx].enqueued
				& !entries[queue_idx].acknowledged;
		end
	endgenerate
	
	arbiter #(.NUM_ENTRIES(`STRANDS_PER_CORE)) next_issue(
		.request(issue_request),
		.update_lru(l2req_ready),
		.grant_oh(issue_oh),
		/*AUTOINST*/
							      // Inputs
							      .clk		(clk),
							      .reset		(reset));

	one_hot_to_index #(.NUM_SIGNALS(`STRANDS_PER_CORE)) cvt_issue_idx(
		.one_hot(issue_oh),
		.index(issue_idx));

	assign l2req_packet.valid = |issue_oh;
	
	assign load_complete_strands_o = (l2rsp_packet.valid && is_for_me)
		? entries[l2rsp_packet.strand].waiting_strands : 0;

	always_ff @(posedge clk, posedge reset)
	begin : update
		if (reset)
		begin
			for (int i = 0; i < `STRANDS_PER_CORE; i = i + 1)
				entries[i] <= 0;
		end
		else
		begin
			// L2 responded to entry that wasn't issued
			assert(!(l2rsp_packet.valid && is_for_me && !entries[l2rsp_packet.strand].enqueued));
			
			// L2 responded to entry that wasn't acknowledged
			assert(!(l2rsp_packet.valid && is_for_me && !entries[l2rsp_packet.strand].acknowledged));
			
			// queued thread on LMQ twice
			assert(!(request_i && !load_already_pending && entries[strand_i].enqueued));

			// load collision on non-pending entry
			assert(!(request_i && !synchronized_i && load_already_pending 
					&& !entries[load_already_pending_entry].enqueued));

			// load_acknowledged conflict
			assert(!(issue_oh != 0 && l2req_ready && l2rsp_packet.valid && is_for_me 
				&& entries[l2rsp_packet.strand].enqueued && l2rsp_packet.strand == issue_idx));

			// Handle enqueueing new requests
			if (request_i)
			begin
				// Note that a synchronized load is a separate command, so we never
				// piggyback it on an existing load.
				if (load_already_pending && !synchronized_i)
				begin
					// Update an existing entry.
					entries[load_already_pending_entry].waiting_strands 
						<= entries[load_already_pending_entry].waiting_strands | (1 << strand_i);
				end
				else
				begin
					// Send a new request.
					entries[strand_i].synchronized <= synchronized_i;
					entries[strand_i].address <= request_addr;
	
					// This is a bit subtle.
					// If a load is already pending (which would only happen if
					// we are doing a synchronized load), we must use the way that is 
					// already queued in that one.  Otherwise use the newly 
					// allocated way.
					if (load_already_pending)
						entries[strand_i].way <= entries[load_already_pending_entry].way;
					else
						entries[strand_i].way <= victim_way_i;
	
					entries[strand_i].enqueued <= 1;
					entries[strand_i].waiting_strands <= (4'b0001 << strand_i);
				end
			end
	
			if (issue_oh != 0 && l2req_ready)
				entries[issue_idx].acknowledged <= 1;
	
			if (l2rsp_packet.valid && is_for_me && entries[l2rsp_packet.strand].enqueued)
			begin
				entries[l2rsp_packet.strand].enqueued <= 0;
				entries[l2rsp_packet.strand].acknowledged <= 0;
			end
		end
	end

`ifdef SIMULATION
	//
	// Validation
	//
	logic[`STRANDS_PER_CORE - 1:0] _debug_strands;
	
	always_ff @(posedge clk)
	begin : check
		if (!reset)
		begin
			// Ensure a strand is not marked waiting on multiple entries	
			_debug_strands = 0;
			for (int _debug_index = 0; _debug_index < `STRANDS_PER_CORE; _debug_index = _debug_index + 1)
			begin
				if (entries[_debug_index].enqueued)
				begin
					if (_debug_strands & entries[_debug_index].waiting_strands)
					begin
						$display("%m: a strand is marked waiting on multiple load queue entries %b", 
							_debug_strands & entries[_debug_index].waiting_strands);
						$finish;
					end

					_debug_strands = _debug_strands | entries[_debug_index].waiting_strands;
				end
			end
		end	
	end
`endif

endmodule