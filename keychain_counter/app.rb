require 'i2c'

# I2C初期化
i2c = I2C.new(unit: :RP2040_I2C1, sda_pin: 26, scl_pin: 27)
LCD_ADDR = 0x27

# --- 在庫データ保存用 (CSV形式) ---
COUNT_FILE = "/home/count.txt"
COUNT_ITEM_RANGE = 0..27
COUNT_ITEM_MIN = 0
COUNT_ITEM_MAX = 27
DEFAULT_COUNT = 0
COUNT_COMPACT_THRESHOLD = 10

# アイテム名、最大10文字まで
ITEM_NAMES = [
  "Item 00", "Item 01", "Item 02", "Item 03",
  "Item 04", "Item 05", "Item 06", "Item 07",
  "Item 08", "Item 09", "Item 10", "Item 11",
  "Item 12", "Item 13", "Item 14", "Item 15",
  "Item 16", "Item 17", "Item 18", "Item 19",
  "Item 20", "Item 21", "Item 22", "Item 23",
  "Item 24", "Item 25", "Item 26", "Item 27"
]

def item_name(id)
  ITEM_NAMES[id] || "Item #{id}"
end


def build_default_count
  data = {}
  COUNT_ITEM_RANGE.each { |i| data[i] = DEFAULT_COUNT }
  data
end

def parse_count_line(line)
  parts = line.chomp.split(",")
  return nil unless parts.size == 2

  id = parts[0].to_i
  count = parts[1].to_i
  return nil unless id >= COUNT_ITEM_MIN && id <= COUNT_ITEM_MAX

  [id, count]
end

# ファイルから在庫を読み込む
def load_count(led)
  data = build_default_count
  line_count = 0

  begin
    File.open(COUNT_FILE, "r") do |f|
      f.each_line do |line|
        parsed = parse_count_line(line)
        next unless parsed
        led.write(1)

        id, count = parsed
        data[id] = count
        line_count += 1
        led.write(0)
      end
    end
  rescue => e
    puts "Load Error: #{e.message}"
  end
  save_count_all(data, led) if line_count > COUNT_COMPACT_THRESHOLD
  data
end

# 圧縮保存: ログが増えたときだけ全体を書き出す
def save_count_all(data, led)
  begin
    File.open(COUNT_FILE, "w") do |f|
      data.each do |id, count|
        led.write(1)
        f.write("#{id},#{count}\n")
        led.write(0)
      end
    end
  rescue => e
    puts "Save Error: #{e.message}"
  end
end

def append_count_update(id, count)
  begin
    File.open(COUNT_FILE, "a") do |f|
      f.write("#{id},#{count}\n")
    end
    true
  rescue => e
    puts "Save Error: #{e.message}"
    false
  end
end

# --- LCD制御メソッド ---
def lcd_send(i2c, val, mode)
  high = mode | (val & 0xF0) | 0x08
  low = mode | ((val << 4) & 0xF0) | 0x08
  [high | 0x04, high, low | 0x04, low].each { |b| i2c.write(LCD_ADDR, b) }
end

def lcd_init(i2c)
  [0x33, 0x32, 0x28, 0x0C, 0x06, 0x01].each { |cmd| lcd_send(i2c, cmd, 0); sleep_ms 2 }
end

def lcd_print(i2c, str, line)
  pos = (line == 0 ? 0x80 : 0xC0)
  lcd_send(i2c, pos, 0)
  padded_str = str.to_s.ljust(16)
  padded_str.each_byte { |b| lcd_send(i2c, b, 1) }
  puts "[LCD L#{line}] #{str}"
end
# ----------------------



# --- 初期設定 ---
led = GPIO.new(25, GPIO::OUT)

# 初期ロード
count = load_count(led)
pending_count_updates = 0

lcd_init(i2c)

# 28キー入力行列 (4行 x 7列)
rows28 = [GPIO.new(7, GPIO::OUT), GPIO.new(8, GPIO::OUT), GPIO.new(9, GPIO::OUT), GPIO.new(10, GPIO::OUT)]
cols28 = [GPIO.new(0, GPIO::IN | GPIO::PULL_UP), GPIO.new(1, GPIO::IN | GPIO::PULL_UP), GPIO.new(2, GPIO::IN | GPIO::PULL_UP),
          GPIO.new(3, GPIO::IN | GPIO::PULL_UP), GPIO.new(4, GPIO::IN | GPIO::PULL_UP), GPIO.new(5, GPIO::IN | GPIO::PULL_UP),
          GPIO.new(6, GPIO::IN | GPIO::PULL_UP)]

# キーパッド入力行列 (4行 x 3列)
rows_kp = [GPIO.new(21, GPIO::OUT), GPIO.new(16, GPIO::OUT), GPIO.new(17, GPIO::OUT), GPIO.new(19, GPIO::OUT)]
cols_kp = [GPIO.new(20, GPIO::IN | GPIO::PULL_UP), GPIO.new(22, GPIO::IN | GPIO::PULL_UP), GPIO.new(18, GPIO::IN | GPIO::PULL_UP)]

KEY_MAP_KP = [
  ["1", "2", "3"],
  ["4", "5", "6"],
  ["7", "8", "9"],
  ["*", "0", "#"]
]

# 2回押し判定用
last_matrix_key = nil
last_pressed_at = 0
DOUBLE_PRESS_MS = 2000  # 2000ミリ秒以内の2回押しで在庫を増やす

state = :normal # :normal, :select_item, :input_value
selected_item = nil
input_buffer = ""

def all_high(rows)
  rows.each { |r| r.write(1) }
end

all_high(rows28)
all_high(rows_kp)

lcd_print(i2c, "Keychain Counter", 0)
lcd_print(i2c, "Ready", 1)

loop do
  # --- キーパッドスキャン ---
  kp_key = nil
  rows_kp.each_with_index do |row, r_idx|
    row.write(0)
    cols_kp.each_with_index do |col, c_idx|
      if col.low?
        kp_key = KEY_MAP_KP[r_idx][c_idx]
        sleep 0.2
      end
    end
    row.write(1)
  end

  # --- 28キー行列スキャン ---
  matrix_key = nil
  rows28.each_with_index do |row, r_idx|
    row.write(0)
    cols28.each_with_index do |col, c_idx|
      if col.low?
        matrix_key = r_idx * 7 + c_idx
        sleep 0.2
      end
    end
    row.write(1)
  end

  # --- 状態遷移ロジック ---
  case state
  when :normal
    if kp_key == "*"
      state = :select_item
      lcd_print(i2c, "SET MODE:", 0)
      lcd_print(i2c, "Select Item(28)", 1)
    elsif kp_key == "#"
      save_count_all(count, led)
      pending_count_updates = 0
      lcd_print(i2c, "Saved!", 0)
      lcd_print(i2c, "Ready", 1)
    elsif matrix_key
      current_time = Time.now.to_f
      # DOUBLE_PRESS_MS 以内の2度押し判定
      if last_matrix_key == matrix_key && (current_time - last_pressed_at) < (DOUBLE_PRESS_MS / 1000.0)
        count[matrix_key] += 1
        if append_count_update(matrix_key, count[matrix_key])
          pending_count_updates += 1
          if pending_count_updates >= COUNT_COMPACT_THRESHOLD
            save_count_all(count, led)
            pending_count_updates = 0
          end
        end
        lcd_print(i2c, item_name(matrix_key), 0)
        lcd_print(i2c, "Added! #{count[matrix_key]}", 1)
        3.times { led.write(1); sleep 0.1; led.write(0); sleep 0.1 }
        # (kiriban_effect removed to avoid OOM)
        last_matrix_key = nil
      else
        # 1度押し：表示
        lcd_print(i2c, item_name(matrix_key), 0)
        lcd_print(i2c, "Count: #{count[matrix_key]}", 1)

        last_matrix_key = matrix_key
        last_pressed_at = current_time
      end
    end

  when :select_item
    if matrix_key
      selected_item = matrix_key
      input_buffer = ""
      state = :input_value
      lcd_print(i2c, "[Set]#{item_name(selected_item)}", 0)
      lcd_print(i2c, "Qty: ", 1)
      # LEDを点滅開始の合図（後述のループ内で制御は難しいのでここで一回）
      3.times { led.write(1); sleep 0.1; led.write(0); sleep 0.1 }
    elsif kp_key == "#" # キャンセル
      state = :normal
      lcd_print(i2c, "Cancelled", 0)
      lcd_print(i2c, "Ready", 1)
    end

  when :input_value
    # LED点滅（簡易的に回す）
    led.write(1)

    if kp_key
      if kp_key >= "0" && kp_key <= "9"
        input_buffer += kp_key
        lcd_print(i2c, "Qty: #{input_buffer}", 1)
      elsif kp_key == "*"
        state = :normal
        led.write(0)
        lcd_print(i2c, "Cancelled", 0)
        lcd_print(i2c, "Ready", 1)
      elsif kp_key == "#"
        if input_buffer.empty?
          state = :normal
          led.write(0)
          lcd_print(i2c, "Cancelled", 0)
          lcd_print(i2c, "Ready", 1)
        else
          count[selected_item] = input_buffer.to_i
          if append_count_update(selected_item, count[selected_item])
            pending_count_updates += 1
            if pending_count_updates >= COUNT_COMPACT_THRESHOLD
              save_count_all(count, led)
              pending_count_updates = 0
            end
          end
          state = :normal
          led.write(0)
          lcd_print(i2c, item_name(selected_item), 0)
          lcd_print(i2c, "Set! #{count[selected_item]}", 1)
        end
      end
    end

    sleep 0.1
    led.write(0)
  end

  # 古い compact_count_file 呼び出し箇所を削除 (save_count_allに統合したため)

  sleep 0.01
end
