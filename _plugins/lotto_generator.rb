require 'json'

module Jekyll
  module LottoText
    module_function

    AMBIG = {}

    def clean_tail(s)
      s.to_s.strip.sub(/[\s\)\]\}\>'"”’.,!?~·\-]+\z/, '')
    end

    def hangul_tail?(s)
      c = clean_tail(s)[-1]
      !c.nil? && c.ord >= 0xAC00 && c.ord <= 0xD7A3
    end

    def batchim?(s)
      c = clean_tail(s)[-1]
      return false if c.nil?
      o = c.ord
      return (o - 0xAC00) % 28 != 0 if o >= 0xAC00 && o <= 0xD7A3
      false
    end

    def josa(word, with_b, without_b)
      return "#{word}#{with_b}(#{without_b})" unless hangul_tail?(word)
      word.to_s + (batchim?(word) ? with_b : without_b)
    end

    def eun_neun(w); josa(w, '은', '는'); end

    def sg_name(do_short, sg)
      AMBIG[sg] ? "#{do_short} #{sg}" : sg
    end

    def fmt(n)
      n.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
    end

    def kind_text(i)
      if i['online'] && i['printed']
        '로또6/45·연금복권720+ 등 온라인복권과 스피또 등 인쇄복권'
      elsif i['online']
        '로또6/45·연금복권720+ 등 온라인복권'
      else
        '스피또 등 인쇄복권'
      end
    end

    def kind_short(i)
      if i['online'] && i['printed'] then '온라인+인쇄복권'
      elsif i['online'] then '온라인복권(로또)'
      else '인쇄복권(스피또)'
      end
    end
  end

  class LottoPageGenerator < Generator
    safe true
    priority :normal

    CAP = 150
    NEAR = 6

    def generate(site)
      items = []
      Dir.glob(File.join(site.source, '_rawdata', 'lot_*.json')).sort.each { |p| items.concat(load_json(p)) }
      dongs = load_json(File.join(site.source, '_rawdata', 'dongs.json'))
      wins = load_json(File.join(site.source, '_rawdata', 'wins.json'))
      return if items.empty?

      LottoText::AMBIG.clear
      items.group_by { |i| i['sigungu'] }.each { |sg, l| LottoText::AMBIG[sg] = true if l.map { |i| i['doShort'] }.uniq.size > 1 }

      dong_index = dongs.each_with_object({}) { |d, h| h[[d['do'], d['sigungu'], d['dong']]] = d }
      by_dong = items.group_by { |i| [i['doShort'], i['sigungu'], i['dong']] }
      by_sg = items.group_by { |i| [i['doShort'], i['sigungu']] }
      do_list = items.map { |i| i['doShort'] }.uniq.sort
      counts = { do: 0, sg: 0, dong: 0, store: 0, win_do: 0, win_sg: 0 }
      store_name = items.each_with_object({}) { |i, h| h[i['slug']] = i }

      wins_by_do = wins.group_by { |w| w['do'] }
      win_total_by_sg = Hash.new(0)
      wins.each { |w| win_total_by_sg[[w['do'], w['sigungu']]] += w['count'].to_i }

      do_list.each do |do_short|
        d_items = items.select { |i| i['doShort'] == do_short }
        sgs = by_sg.keys.select { |dd, _| dd == do_short }.map { |_, s| s }.sort
        sg_rows = sgs.map do |sg|
          l = by_sg[[do_short, sg]]
          { 'name' => sg, 'slug' => l.first['sgSlug'], 'count' => l.size, 'win' => l.sum { |i| i['winCount'] } }
        end.sort_by { |h| [-h['count'], h['name']] }
        site.pages << LottoDoPage.new(site, do_short, d_items, sg_rows, wins_by_do[do_short] || [])
        counts[:do] += 1

        sgs.each do |sg|
          sg_items = by_sg[[do_short, sg]]
          sg_slug = sg_items.first['sgSlug']
          sg_dongs = sg_items.group_by { |i| i['dong'] }.map { |dg, l| { 'name' => dg, 'count' => l.size } }
                             .sort_by { |h| h['name'] == '기타' ? [1, 0, ''] : [0, -h['count'], h['name']] }
          sg_wins = (wins_by_do[do_short] || []).select { |w| w['sigungu'] == sg || w['sigungu'].start_with?(sg) || sg.start_with?(w['sigungu']) }
          site.pages << LottoSigunguPage.new(site, do_short, sg, sg_slug, sg_items, sg_dongs, sg_wins)
          counts[:sg] += 1

          sg_items.group_by { |i| i['dong'] }.each do |dong, list|
            info = dong_index[[do_short, sg, dong]]
            site.pages << LottoDongPage.new(site, do_short, sg, sg_slug, dong, list, info)
            counts[:dong] += 1
            sorted = list.sort_by { |i| i['dongRank'] }
            name_cnt = Hash.new(0)
            sorted.each { |x| name_cnt[x['storeName']] += 1 }
            sorted.each_with_index do |c, idx|
              c['dupName'] = name_cnt[c['storeName']] > 1
              ring = sorted.size > 1 ? (1..[4, sorted.size - 1].min).map { |k| sorted[(idx + k) % sorted.size] } : []
              site.pages << LottoStorePage.new(site, c, ring, info)
              counts[:store] += 1
            end
          end
        end
      end

      # 당첨 판매점 허브
      site.pages << LottoWinIndexPage.new(site, wins, do_list)
      wins_by_do.each do |do_short, ws|
        next unless do_list.include?(do_short)
        site.pages << LottoWinDoPage.new(site, do_short, ws)
        counts[:win_do] += 1
        ws.group_by { |w| w['sigungu'] }.each do |sg, l|
          site.pages << LottoWinSgPage.new(site, do_short, sg, l, store_name)
          counts[:win_sg] += 1
        end
      end

      matched = items.select { |i| i['winCount'] > 0 }
      top_dongs = dongs.select { |d| d['shopCount'].to_i > 0 }.sort_by { |d| [-d['shopCount'], d['dong']] }.first(30)
      site.data['lotto_stats'] = {
        'total' => items.size, 'total_fmt' => LottoText.fmt(items.size), 'dong_fmt' => LottoText.fmt(dongs.size),
        'win_stores' => wins.size, 'win_sum' => wins.sum { |w| w['count'].to_i },
        'do_counts' => do_list.map { |d| { 'name' => d, 'count' => items.count { |i| i['doShort'] == d }, 'win' => (wins_by_do[d] || []).size } },
        'top_dongs' => top_dongs.map { |d| { 'url' => "/region/#{d['do']}/#{d['sgSlug']}/#{d['dong']}/", 'label' => "#{d['do']} #{d['sigungu']} #{d['dong']}", 'count' => d['shopCount'] } },
        'matched' => matched.size
      }
      Jekyll.logger.info 'LottoGenerator:', counts.map { |k, v| "#{k} #{v}" }.join(' / ')
    end

    private

    def load_json(path)
      JSON.parse(File.read(path, encoding: 'utf-8'))
    rescue => e
      Jekyll.logger.warn 'LottoGenerator:', "#{path} 로드 실패: #{e.message}"
      []
    end
  end

  class LottoBasePage < Page
    def setup(site, dir, layout)
      @site = site
      @base = site.source
      @dir = dir
      @name = 'index.html'
      process(@name)
      read_yaml(File.join(@base, '_layouts'), "#{layout}.html")
      data['layout'] = layout
    end

    def seo(title, desc)
      data['title'] = title
      data['description'] = desc[0, 155]
    end

    def make_faq(pairs)
      data['faq'] = pairs.map { |q, a| { 'q' => q, 'a' => a } }
    end

    def win_sentence(ws)
      return '' if ws.empty?
      total = ws.sum { |w| w['count'].to_i }
      "최근 1년(2025년 6월~2026년 6월) 로또6/45 1등 자동 당첨이 나온 판매점은 #{ws.size}곳, 당첨 #{total}건입니다."
    end
  end

  class LottoDoPage < LottoBasePage
    def initialize(site, do_short, d_items, sg_rows, ws)
      setup(site, "region/#{do_short}", 'do')
      data['doShort'] = do_short
      data['totalCount'] = d_items.size
      data['sigunguList'] = sg_rows
      data['winCount'] = ws.size
      data['winTotal'] = ws.sum { |w| w['count'].to_i }
      seo("#{do_short} 로또 판매점 #{LottoText.fmt(d_items.size)}곳 - 시군구별 복권방 위치·1등 당첨점",
          "#{do_short}의 로또·복권 판매점 #{LottoText.fmt(d_items.size)}곳을 시군구·동별로 찾아보세요. 판매점 주소와 최근 1년 1등 자동 당첨 판매점 #{ws.size}곳 정보를 공공데이터로 안내합니다.")
    end
  end

  class LottoSigunguPage < LottoBasePage
    def initialize(site, do_short, sg, sg_slug, items, sg_dongs, sg_wins)
      setup(site, "region/#{do_short}/#{sg_slug}", 'sigungu')
      sgn = LottoText.sg_name(do_short, sg)
      data['doShort'] = do_short
      data['sigungu'] = sg
      data['sgSlug'] = sg_slug
      data['sgLabel'] = sgn
      data['totalCount'] = items.size
      data['dongList'] = sg_dongs
      data['onlineCount'] = items.count { |i| i['online'] }
      data['printedOnly'] = items.count { |i| !i['online'] }
      data['wins'] = sg_wins.sort_by { |w| [-w['count'].to_i, w['name']] }.map { |w| w.merge('slug' => (w['slugs'].size == 1 ? w['slugs'].first : nil)) }
      s = +"#{do_short} #{sg}에는 복권 판매점이 #{items.size}곳 등록되어 있고, 이 중 로또6/45·연금복권을 파는 온라인복권 판매점은 #{data['onlineCount']}곳입니다."
      s << " #{win_sentence(sg_wins).sub('최근 1년', "#{sg}에서 최근 1년")}" unless sg_wins.empty?
      s << ' 동네를 선택해 가까운 복권방을 찾아보세요.'
      data['summary'] = s
      seo("#{sgn} 로또 판매점 #{items.size}곳 - 동별 복권방 위치#{sg_wins.empty? ? '' : '·1등 당첨점'}",
          "#{do_short} #{sg}의 로또·복권 판매점 #{items.size}곳을 동별로 확인하세요.#{sg_wins.empty? ? '' : " 최근 1년 1등 자동 당첨 판매점 #{sg_wins.size}곳 포함."} 판매점 주소와 근처 판매점 안내.")
    end
  end

  class LottoDongPage < LottoBasePage
    def initialize(site, do_short, sg, sg_slug, dong, list, info)
      setup(site, "region/#{do_short}/#{sg_slug}/#{dong}", 'dong')
      sgn = LottoText.sg_name(do_short, sg)
      label = dong == '기타' ? '기타 지역' : dong
      sorted = list.sort_by { |i| [-i['winCount'], i['storeName']] }
      data['doShort'] = do_short
      data['sigungu'] = sg
      data['sgSlug'] = sg_slug
      data['sgLabel'] = sgn
      data['dong'] = dong
      data['dongLabel'] = label
      data['totalCount'] = list.size
      data['items'] = sorted.first(LottoPageGenerator::CAP).map { |i| i.slice('slug', 'storeName', 'addr', 'online', 'printed', 'winCount', 'winPossible', 'winSame') }
      data['truncated'] = list.size > LottoPageGenerator::CAP
      data['nearDongs'] = info ? info['nearDongs'].first(8) : []
      winners = list.select { |i| i['winCount'] > 0 }
      possible = list.select { |i| i['winCount'] == 0 && i['winPossible'].to_i > 0 }
      data['winners'] = winners.map { |i| i.slice('slug', 'storeName', 'addr', 'winCount') }
      online = list.count { |i| i['online'] }
      s = +"#{do_short} #{sg} #{label}에는 복권 판매점이 #{list.size}곳 등록되어 있고, 로또6/45·연금복권을 파는 온라인복권 판매점은 #{online}곳입니다."
      if winners.any?
        s << " 최근 1년 1등 자동 당첨이 확인된 판매점은 #{winners.map { |w| w['storeName'] }.first(3).join(', ')}#{winners.size > 3 ? ' 등' : ''}입니다."
      elsif possible.any?
        s << " 이 동네에는 최근 1년 1등 자동 당첨 판매점과 상호가 같은 곳이 #{possible.size}곳 있지만, 동일 상호가 여러 곳이라 어느 점포인지는 공공데이터로 구분되지 않습니다."
      else
        s << ' 최근 1년 1등 자동 당첨 판매점으로 확인된 곳은 없습니다.'
      end
      data['summary'] = s
      seo("#{sgn} #{label} 로또 판매점 #{list.size}곳 - 복권방 위치·주소#{winners.any? ? '·1등 당첨점' : ''}",
          "#{do_short} #{sg} #{label}의 로또·복권 판매점 #{list.size}곳 목록. 판매점별 주소와 취급 복권, 근처 동네 복권방#{winners.any? ? ', 최근 1년 1등 자동 당첨점' : ''}을 확인하세요.")
      pairs = []
      pairs << ["#{label}에 로또 파는 곳이 있나요?", "공공데이터 기준 #{do_short} #{sg} #{label}에는 복권 판매점이 #{list.size}곳 있고, 그중 로또6/45를 파는 온라인복권 판매점은 #{online}곳입니다."]
      pairs << ["#{label} 근처 복권방 1등 당첨 이력은요?", winners.any? ? "최근 1년(1176~1227회차) 1등 자동 당첨이 확인된 판매점은 #{winners.map { |w| "#{w['storeName']}(#{w['winCount']}회)" }.join(', ')}입니다. 수동 선택 당첨은 데이터에 없습니다." : "공공데이터에는 #{label}의 판매점 중 최근 1년 1등 자동 당첨으로 확인된 곳이 없습니다. 이 데이터는 자동 선택 1등만 포함하며 매년 갱신됩니다."]
      pairs << ['당첨 판매점에서 사면 당첨 확률이 높아지나요?', '아닙니다. 로또6/45 1등 확률은 매 회차 약 814만분의 1로 어느 판매점에서 사도 같습니다. 당첨 횟수가 많은 판매점은 판매량이 많아서인 경우가 대부분입니다.']
      make_faq(pairs)
    end
  end

  class LottoStorePage < LottoBasePage
    def initialize(site, c, ring, info)
      setup(site, "store/#{c['slug']}", 'store')
      data.merge!(c)
      sgn = LottoText.sg_name(c['doShort'], c['sigungu'])
      dl = c['dong'] == '기타' ? '기타 지역' : c['dong']
      dong_part = c['dong'] == '기타' ? '' : " #{c['dong']}"
      name = c['storeName']
      data['dongLabel'] = dl
      data['sgLabel'] = sgn
      data['kindText'] = LottoText.kind_text(c)
      data['kindShort'] = LottoText.kind_short(c)
      data['near'] = c['near'].map { |x| x.merge('dist' => (x['m'] < 1000 ? "#{x['m']}m" : "약 #{(x['m'] / 1000.0).round(1)}km")) }
      data['ring'] = ring.map { |x| { 'slug' => x['slug'], 'name' => x['storeName'], 'win' => x['winCount'] } }
      data['nearDongs'] = info ? info['nearDongs'].first(6) : []
      s = +"#{LottoText.eun_neun(name)} #{c['doShort']} #{c['sigungu']}#{dong_part}에 있는 복권 판매점이며, 취급 복권은 #{data['kindText']}입니다."
      if c['winCount'].to_i > 0
        s << " 최근 1년(1176~1227회차) 로또6/45 1등 자동 당첨이 #{c['winCount']}회 확인된 판매점입니다."
      elsif c['winPossible'].to_i > 0
        s << " 같은 상호의 판매점이 #{c['winSame']}곳 있는 지역에서 최근 1년 1등 자동 당첨이 나왔지만, 이 점포가 해당 판매점인지는 공공데이터로 구분되지 않습니다."
      end
      if c['dongCount'].to_i > 1
        s << " #{dl}의 복권 판매점 #{c['dongCount']}곳 중 하나입니다."
      end
      data['summary'] = s
      first_near = c['near'].first
      toks = c['addr'].sub(/\s*\(.*\z/, '').split(' ')
      k = toks.each_index.find { |ti| ti >= 2 && toks[ti] =~ /\A\d+(-\d+)?,?\z/ }
      road_hint = c['dupName'] ? " (#{k ? "#{toks[k - 1]} #{toks[k].sub(/,\z/, '')}" : toks.last(2).join(' ')})" : ''
      seo("#{name}#{road_hint} - #{sgn}#{dong_part} 로또·복권 판매점 주소#{c['winCount'].to_i > 0 ? " (1등 자동 #{c['winCount']}회)" : ''}",
          "#{c['doShort']} #{c['sigungu']}#{dong_part} 복권 판매점 #{name}. 주소 #{c['addr']}. #{c['online'] ? '로또6/45·연금복권 판매' : '스피또 등 인쇄복권 판매'}.#{first_near ? " 근처 #{first_near['name']}(#{first_near['m']}m)." : ''}")
      pairs = []
      pairs << ["#{LottoText.eun_neun(name)} 어디에 있나요?", "주소는 #{c['addr']}입니다. #{c['doShort']} #{c['sigungu']}#{dong_part}에 있습니다."]
      pairs << ["#{name}에서 로또를 살 수 있나요?", c['online'] ? "공공데이터에 온라인복권(로또6/45·연금복권720+) 판매점으로 등록되어 있습니다. 영업 여부와 영업시간은 방문 전에 확인하세요." : "이곳은 스피또 등 인쇄복권 판매점으로 등록되어 있고, 로또6/45 같은 온라인복권 판매점으로는 확인되지 않습니다."]
      pairs << ["#{name}의 1등 당첨 이력은요?", c['winCount'].to_i > 0 ? "최근 1년(1176~1227회차) 로또6/45 1등 자동 당첨이 #{c['winCount']}회 확인됩니다. 수동 선택 당첨과 그 이전 이력은 공공데이터에 없습니다." : "공공데이터에서 이 판매점의 최근 1년 1등 자동 당첨은 확인되지 않습니다. 자동 선택 1등만 공개되며 수동 선택 당첨은 포함되지 않습니다."]
      pairs << ['당첨 판매점에서 사면 확률이 높아지나요?', '아닙니다. 로또6/45 1등 확률은 매 회차 약 814만분의 1로 판매점과 무관하게 같습니다. 당첨 횟수는 판매량이 많은 점포일수록 많게 나오는 경향이 있습니다.']
      make_faq(pairs)
    end
  end

  class LottoWinIndexPage < LottoBasePage
    def initialize(site, wins, do_list)
      setup(site, 'win', 'win_index')
      data['totalStores'] = wins.size
      data['totalWins'] = wins.sum { |w| w['count'].to_i }
      data['top'] = wins.sort_by { |w| [-w['count'].to_i, w['do'], w['name']] }.first(40).map { |w| w.merge('slug' => (w['slugs'].size == 1 ? w['slugs'].first : nil)) }
      data['doRows'] = wins.group_by { |w| w['do'] }.map { |d, l| { 'name' => d, 'count' => l.size, 'sum' => l.sum { |w| w['count'].to_i } } }.sort_by { |h| -h['count'] }
      seo("로또 1등 당첨 판매점 #{wins.size}곳 - 최근 1년 지역별 명당 (1176~1227회차)",
          "최근 1년(2025년 6월~2026년 6월) 로또6/45 1등 자동 당첨 판매점 #{wins.size}곳을 지역별로 확인하세요. 기획예산처 공공데이터 기준 시도·시군구별 1등 배출 판매점.")
      make_faq([['로또 1등 당첨 판매점은 어디서 확인하나요?', '기획예산처가 공공데이터포털에 1년 단위로 공개하는 온라인복권 1등 당첨 판매점 현황을 정리했습니다. 이 자료는 자동 선택 1등만 포함하며 판매점 주소 없이 시군구까지만 공개됩니다.'],
                ['당첨 횟수가 많은 판매점은 명당인가요?', '당첨 횟수는 판매량이 많을수록 늘어나는 경향이 있고, 로또 1등 확률은 판매점과 무관하게 매 회차 같습니다. 참고용 정보로만 활용하세요.']])
    end
  end

  class LottoWinDoPage < LottoBasePage
    def initialize(site, do_short, ws)
      setup(site, "win/#{do_short}", 'win_do')
      data['doShort'] = do_short
      data['totalStores'] = ws.size
      data['totalWins'] = ws.sum { |w| w['count'].to_i }
      data['sgRows'] = ws.group_by { |w| w['sigungu'] }.map { |sg, l| { 'name' => sg, 'slug' => sg.tr(' ', '-'), 'count' => l.size, 'sum' => l.sum { |w| w['count'].to_i } } }.sort_by { |h| [-h['count'], h['name']] }
      seo("#{do_short} 로또 1등 당첨 판매점 #{ws.size}곳 - 최근 1년 시군구별",
          "#{do_short}에서 최근 1년(1176~1227회차) 로또6/45 1등 자동 당첨이 나온 판매점 #{ws.size}곳을 시군구별로 확인하세요. 기획예산처 공공데이터 기준.")
    end
  end

  class LottoWinSgPage < LottoBasePage
    def initialize(site, do_short, sg, ws, store_name)
      setup(site, "win/#{do_short}/#{sg.tr(' ', '-')}", 'win_sg')
      sgn = LottoText.sg_name(do_short, sg)
      data['doShort'] = do_short
      data['sigungu'] = sg
      data['sgLabel'] = sgn
      data['totalStores'] = ws.size
      data['totalWins'] = ws.sum { |w| w['count'].to_i }
      data['rows'] = ws.sort_by { |w| [-w['count'].to_i, w['name']] }.map do |w|
        cands = w['slugs'].map { |sl| store_name[sl] }.compact
        w.merge('single' => (cands.size == 1 ? cands.first['slug'] : nil), 'candidates' => cands.first(6).map { |c| { 'slug' => c['slug'], 'addr' => c['addr'], 'dong' => c['dong'] } }, 'candN' => cands.size)
      end
      sg_slug = (store_name.values.find { |c| c['doShort'] == do_short && c['sigungu'] == sg } || {})['sgSlug']
      data['regionSlug'] = sg_slug
      seo("#{sgn} 로또 1등 당첨 판매점 #{ws.size}곳 - 최근 1년 명당 (자동 #{data['totalWins']}건)",
          "#{do_short} #{sg}에서 최근 1년 로또6/45 1등 자동 당첨이 나온 판매점 #{ws.size}곳: #{ws.sort_by { |w| -w['count'].to_i }.first(3).map { |w| w['name'] }.join(', ')} 등. 공공데이터 기준.")
      make_faq([["#{sg} 로또 1등 당첨 판매점은 어디인가요?", "기획예산처 공공데이터 기준 최근 1년(1176~1227회차) #{do_short} #{sg}에서 1등 자동 당첨이 나온 판매점은 #{ws.map { |w| w['name'] }.join(', ')}입니다."],
                ['판매점 주소는 왜 시군구까지만 나오나요?', '공공데이터에 판매점 상호와 시군구만 공개되기 때문입니다. 같은 상호의 판매점이 여러 곳이면 어느 점포인지 구분되지 않아 후보 판매점을 함께 보여줍니다.']])
    end
  end

  class LottoSitemapGenerator < Generator
    safe true
    priority :lowest
    CHUNK = 40_000

    def generate(site)
      urls = site.pages.reject { |p| p.url.to_s.end_with?('.json', '.xml', '.txt', '.js', '.css') || p.url.to_s == '/404.html' || p.data['sitemap'] == false }
                       .map { |p| p.url }.uniq
      base = site.config['url'].to_s
      chunks = urls.each_slice(CHUNK).to_a
      chunks.each_with_index do |c, idx|
        body = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
        c.each { |u| body << "  <url><loc>#{base}#{u}</loc></url>\n" }
        body << "</urlset>\n"
        site.pages << raw_page(site, "sitemap-#{idx + 1}.xml", body)
      end
      index = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
      chunks.each_index { |idx| index << "  <sitemap><loc>#{base}/sitemap-#{idx + 1}.xml</loc></sitemap>\n" }
      index << "</sitemapindex>\n"
      site.pages << raw_page(site, 'sitemap.xml', index)
      Jekyll.logger.info 'LottoSitemap:', "#{urls.size}개 URL → #{chunks.size}개 사이트맵"
    end

    private

    def raw_page(site, name, content)
      pg = PageWithoutAFile.new(site, site.source, '', name)
      pg.content = content
      pg.data['layout'] = nil
      pg.data['sitemap'] = false
      pg
    end
  end
end
