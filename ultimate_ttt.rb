require 'digest'
require 'yaml'
require 'colorize'

CACHE_FILE = "utt_cache_digest.yml"

$dev = nil
loop do
  puts "Dev mode? (Y/N)"
  input = gets.chomp.strip.upcase
  if input == "Y"
    $dev = true
    break
  elsif input == "N"
    $dev = false
    break
  else
    puts "Invalid input, please enter Y or N."
  end
end

$print_depth = nil
if $dev
  loop do
    puts "Enter minimum depth to print pruned and evaluated paths (or leave empty for all):"
    input = gets.chomp.strip
    if input.empty?
      $print_depth = nil
      break
    elsif input =~ /^\d+$/
      $print_depth = input.to_i
      break
    else
      puts "Invalid input, please enter a non-negative integer or leave empty."
    end
  end
end

# -------------------
# Numpad ↔ internal index mapping helpers
# -------------------
def numpad_to_index(n)
  { 1 => 6, 2 => 7, 3 => 8, 4 => 3, 5 => 4, 6 => 5, 7 => 0, 8 => 1, 9 => 2 }[n]
end

def index_to_numpad(idx)
  { 0 => 7, 1 => 8, 2 => 9, 3 => 4, 4 => 5, 5 => 6, 6 => 1, 7 => 2, 8 => 3 }[idx]
end

# -------------------
# Helpers
# -------------------

# -------------------
# Clear screen (cross-platform)
# -------------------
def clear_screen
  system("cls") || system("clear")
end

def winner(board)
  lines = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]
  lines.each { |a,b,c| return board[a] if board[a] != " " && board[a] == board[b] && board[a] == board[c] }
  nil
end

def winning_line_big(boards)
  big_board = boards.map { |b| winner(b) || (full?(b) ? "-" : " ") }
  lines = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]]
  lines.each do |a,b,c|
    return [a,b,c] if big_board[a] != " " && big_board[a] != "-" && big_board[a] == big_board[b] && big_board[a] == big_board[c]
  end
  []
end

def full?(board)
  !board.include?(" ")
end

def overall_winner(boards)
  big = boards.map { |b| winner(b) || (full?(b) ? "-" : " ") }
  winner(big)
end

def serialize(boards, available_boards, current_player)
  Digest::SHA256.hexdigest(boards.flatten.join + available_boards.join + current_player)
end

def possible_moves_dict(boards, available_boards)
  moves = {}
  available_boards.each do |bidx|
    empty = (0..8).select { |i| boards[bidx][i] == " " }
    moves[bidx] = empty unless empty.empty?
  end
  moves
end

def heuristic(boards)
  score = 0
  boards.each do |b|
    w = winner(b)
    score += 1 if w == "X"
    score -= 1 if w == "O"
  end
  score
end

def finalize_board!(boards)
  boards.each_with_index do |b, idx|
    w = winner(b)
    if w
      boards[idx] = Array.new(9, w)
    elsif full?(b)
      boards[idx] = Array.new(9, "-")
    end
  end
end

# -------------------
# Minimax with depth-aware caching
# -------------------
def definite_score?(score, boards)
  score == 1 || score == -1 || score == 0 && overall_winner(boards)
end

def minimax(boards, available_boards, depth, maximizing, max_depth=MAX_DEPTH, alpha=-Float::INFINITY, beta=Float::INFINITY)
  key = serialize(boards, available_boards, maximizing ? "X" : "O")

  # Use cached score only if it is from a deeper or equal depth **and** is definitive
  if $seen.key?(key) && $seen[key][:depth] >= depth && definite_score?($seen[key][:score], boards)
    return $seen[key][:score]
  end

  ow = overall_winner(boards)
  if ow
    score = ow=="X" ? 1 : ow=="O" ? -1 : 0
    # Always store definite outcome
    $seen[key] = { depth: depth, score: score }
    return score
  end

  if max_depth && depth >= max_depth
    score = heuristic(boards)
    # Only store if not already a definite score
    if !$seen.key?(key) || !definite_score?($seen[key][:score], boards)
      $seen[key] = { depth: depth, score: score }
    end
    return score
  end

  player = maximizing ? "X" : "O"
  best_score = maximizing ? -Float::INFINITY : Float::INFINITY

  moves = possible_moves_dict(boards, available_boards)
  moves.each do |bidx, positions|
    positions.each do |pos|
      if $dev && (!$print_depth || depth <= $print_depth)
        print "\r#{' ' * 50}\rEvaluating move #{[bidx,pos]} at depth #{depth}".colorize(:grey)
      end

      copy = Marshal.load(Marshal.dump(boards))
      copy[bidx][pos] = maximizing ? "X" : "O"

      # Correct next available board
      next_board = pos
      next_available = if winner(copy[next_board]) || full?(copy[next_board])
                         (0..8).to_a
                       else
                         [next_board]
                       end

      score = minimax(copy, next_available, depth + 1, !maximizing, max_depth, alpha, beta)

      if maximizing
        best_score = [best_score, score].max
        alpha = [alpha, best_score].max
      else
        best_score = [best_score, score].min
        beta = [beta, best_score].min
      end

      # **Prune branch if we can**
      if beta <= alpha
        # developer
        if $dev && (!$print_depth || depth <= $print_depth)
          print "\r#{' ' * 50}\rPrunned move at depth #{depth}.".colorize(:grey)
        end
        break
      end
    end
  end

  # Update cache: overwrite only if new score is definite or depth is higher
  if !$seen.key?(key) || definite_score?(best_score, boards) || $seen[key][:depth] <= depth
    $seen[key] = { depth: depth, score: best_score }
  end
  best_score
end

def best_moves(boards, available_boards, maximizing)

  player = maximizing ? "X" : "O"
  moves = possible_moves_dict(boards, available_boards)
  scores = {}
  best_score = maximizing ? -Float::INFINITY : Float::INFINITY

  total_moves = moves.values.map(&:size).sum
  moves_done = 0

  moves.each do |bidx, positions|
    positions.each do |pos|
      copy = Marshal.load(Marshal.dump(boards))
      copy[bidx][pos] = player

      # Correct next available board
      next_board = pos
      next_available = if winner(copy[next_board]) || full?(copy[next_board])
                         (0..8).to_a
                       else
                         [next_board]
                       end

      score = minimax(copy, next_available, 0, !maximizing)
      scores[[bidx,pos]] = score
      best_score = maximizing ? [best_score, score].max : [best_score, score].min

      if !$dev
        moves_done += 1
        blocks = ((moves_done.to_f / total_moves) * 10).round
        percent = ((moves_done.to_f / total_moves) * 100).round
        print "\r[#{'█' * blocks}#{'-' * (10 - blocks)}] #{percent}%"
      end
    end
  end

  print "\r[#{'█' * 10}] 100%\n" unless $dev

  best = scores.select { |_, s| s == best_score }.keys
  dict = {}
  best.each { |b,p| (dict[b] ||= []) << p }
  [dict, best.sample]
end

# -------------------
# Board printing with completed boards filled, colors, and highlighting available boards
# Empty cells display 1-9 instead of blank
# X = red, O = blue, available boards yellow numbers
# -------------------
def print_boards(boards, available_boards=[], last_move=nil)
  winning_line = winning_line_big(boards)

  boards.each_slice(3).with_index do |row, row_idx|
    3.times do |i|
      line_parts = []

      row.each_with_index do |b, col_idx|
        board_index = row_idx*3 + col_idx
        cells = []

        b[i*3,3].each_with_index do |c, idx|
          pos = i*3 + idx
          numpad_num = index_to_numpad(pos)

          if c == " "
            if available_boards.include?(board_index)
              cells << numpad_num.to_s.colorize(:yellow)
            else
              cells << numpad_num.to_s.colorize(:grey)
            end
          else
            colored = case c
                      when "X" then c.colorize(:red)
                      when "O" then c.colorize(:blue)
                      when "-" then c.colorize(:magenta) # purple
                      else c
                      end

            # Highlight last move in green (still using internal index!)
            if last_move && last_move == [board_index, pos]
              colored = colored.colorize(:green)
            end

            # Highlight big board winning line
            if winning_line.include?(board_index)
              colored = colored.colorize(:green)
            end

            cells << colored
          end
        end

        line_parts << cells.join(" ")
      end

      puts line_parts.join(" | ")
    end
    puts "------+-------+------"
  end
end

# -------------------
# Ask player
# -------------------
num_players = nil
loop do
  puts "Number of players (0-2):"
  input = gets.chomp
  if input =~ /^[0-2]$/   # matches only 0, 1, or 2
    num_players = input.to_i
    break
  else
    puts "Invalid number, must be 0, 1, or 2."
  end
end

# Initialite arrays
player_enabled = [false, false] # two player slots
player_marks   = [nil, nil]
ai_marks       = [nil, nil]

case num_players
when 0
  # PvE: AI vs AI
  ai_marks = ["X", "O"]
when 1
  # PvAI: Human vs AI
  player_enabled[0] = true
  human_pick = ["X","O"].sample
  player_marks[0] = human_pick
  ai_marks[0] = human_pick=="X" ? "O" : "X"
  puts "You are #{player_marks[0]}, AI is #{ai_marks[0]}"
when 2
  # PvP: Human vs Human
  player_enabled = [true, true]
  player_marks = ["X", "O"]
end

# Determine who starts
# X always starts
maximizing = true
if num_players == 1 && player_marks[0] == "O"
  # Human is O, AI (X) gues first
  maximizing = false
end

# Load cache and define heuristic
if player_enabled.include?(false) || num_players == 0
  MAX_DEPTH = loop do
    puts "Define heuristic depth (0 = normal depth, empty = full minimax, higher numbers limit search depth, tip: use 2):"
    input = gets.chomp.strip

    if input.empty?
      break nil   # empty → full minimax
    elsif input =~ /^\d+$/ && input.to_i >= 0
      break input.to_i   # valid integer ≥ 0
    else
      puts "Invalid input, please enter a non-negative integer or leave empty for full minimax."
    end
  end

  if File.exist?(CACHE_FILE)
    file_size = File.size(CACHE_FILE)
    loaded_data = ""
    read_bytes = 0

    File.open(CACHE_FILE, "r") do |f|
      while chunk = f.read(1024)  # read in 1KB chunks
        loaded_data << chunk
        read_bytes += chunk.bytesize
        percent = ((read_bytes.to_f / file_size) * 100).to_i
        blocks = (percent / 10)
        print "\r[" + "█" * blocks + "-" * (10 - blocks) + "] #{percent}%"
      end
    end

    puts "\nParsing cache..."
    $seen = YAML.safe_load(loaded_data, permitted_classes: [Symbol]) || {}
    $seen = {} unless $seen.is_a?(Hash)
  else
    $seen = {}
  end
else
  $seen = {}
end

# -------------------
# Game loop
# -------------------
boards = Array.new(9) { Array.new(9, " ") }
available_boards = (0..8).to_a

puts "Initial board:"
print_boards(boards, available_boards)

loop do
  ow = overall_winner(boards)
  break puts("Winner: #{ow}") if ow
  break puts("Draw!") if boards.all? { |b| full?(b) }

  # Determine current player
  current_player_idx = maximizing ? 0 : 1
  current_mark = maximizing ? "X" : "O"
  current_is_human = player_enabled[current_player_idx]

  if current_is_human
    # -------------------
    # Human move
    # -------------------
    # Board selection
    bidx = if available_boards.size == 1
      available_boards[0].tap { |b| puts "Only one board available, automatically choosing board #{index_to_numpad(b)}" }
    else
      loop do
        puts "Player #{current_player_idx + 1} (#{player_marks[current_player_idx]}) turn! Available boards: #{available_boards.map { |b| index_to_numpad(b) }.sort}"
        puts "Enter board index (1-9, numpad layout):"
        input_bnum = gets.chomp
        exit if ["quit", "exit"].include?(input_bnum.downcase)
        if input_bnum =~ /^[1-9]$/  # validate digits 1-9
          idx = numpad_to_index(input_bnum.to_i)
          if available_boards.include?(idx)
            break idx
          else
            puts "That board is not available."
          end
        else
          puts "Invalid input, enter a number 1-9."
        end
      end
    end

    # Cell selection
    pos = loop do
      puts "Enter cell index (numpad number 1-9):"
      input_pos = gets.chomp
      exit if ["quit", "exit"].include?(input_pos.downcase)
      if input_pos =~ /^[1-9]$/  # validate digits 1-9
        idx = numpad_to_index(input_pos.to_i)
        if boards[bidx][idx] == " "
          break idx
        else
          puts "That cell is already occupied."
        end
      else
        puts "Invalid input, enter a number 1-9."
      end
    end
    clear_screen
  else
    # -------------------
    # AI move
    # -------------------
    dict, move = best_moves(boards, available_boards, maximizing)

    # convert dict to numpad layout for printing
    best_display = dict.transform_keys { |k| index_to_numpad(k) }
    best_display.each do |b, ps|
      best_display[b] = ps.map { |p| index_to_numpad(p) }.sort
    end
    best_display = best_display.sort.to_h

    puts "\nBest moves: #{best_display}\n\n"
    bidx, pos = move
  end

  # Apply move
  boards[bidx][pos] = current_mark

  # Finalize completed boards
  finalize_board!(boards)

  # Determine next available boards
  next_board = pos
  available_boards = if winner(boards[next_board]) || full?(boards[next_board])
                       (0..8).to_a
                     else
                       [next_board]
                     end

  puts "Board after move #{index_to_numpad(bidx)}-#{index_to_numpad(pos)}:"
  print_boards(boards, available_boards, [bidx, pos])

  # Indicate next player's turn
  if overall_winner(boards).nil? && !boards.all? { |b| full?(b) }
    next_mark = maximizing ? 'O' : 'X'
    colored_mark = next_mark == "X" ? next_mark.colorize(:red) : next_mark.colorize(:blue)
    puts "\nNext turn: #{colored_mark}"
  end

  # Switch turn
  maximizing = !maximizing
end

# -------------------
# Save cache
# -------------------
if player_enabled.include?(false) || num_players == 0
  File.open(CACHE_FILE, "w") { |f| f.write($seen.to_yaml) }
end
